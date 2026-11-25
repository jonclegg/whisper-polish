import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Observation

enum FixShortcutRegistrationError: LocalizedError, Equatable {
    case taken(shortcut: String)
    case refused(shortcut: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case let .taken(shortcut):
            return "\(shortcut) is already used by another app. Quit that app or choose another shortcut."
        case let .refused(shortcut, status):
            return "macOS would not register \(shortcut) (error \(status)). Choose another shortcut."
        }
    }
}

/// The fix shortcut, registered with the Carbon hot key API rather than
/// matched in HotkeyMonitor's event tap. While secure event input is on —
/// a password field anywhere, or loginwindow holding it stuck, which macOS
/// does not clear until logout — event taps get flagsChanged but no keyDown,
/// so a tap never sees ⌘⇧1. The system still delivers registered hot keys
/// then. The dictation key is a bare modifier, a flagsChanged event, so it
/// stays in the tap.
///
/// Registered exclusively, so a combination another app already owns fails
/// loudly instead of the two apps both firing on one press.
@MainActor
@Observable
final class FixShortcutRegistration {
    /// Why the last `register` failed; nil once one succeeds. Settings shows
    /// it next to the recorder.
    private(set) var registrationError: FixShortcutRegistrationError?

    @ObservationIgnored private let onPress: @MainActor () -> Void
    @ObservationIgnored private var hotKey: EventHotKeyRef?
    @ObservationIgnored private var handler: EventHandlerRef?

    /// Tags this app's hot key in the events Carbon delivers to the handler.
    /// Read from the C callback, so not main-actor isolated.
    nonisolated private static let signature: OSType = 0x4457_4658  // "DWFX"
    nonisolated private static let identifier: UInt32 = 1

    init(onPress: @escaping @MainActor () -> Void) {
        self.onPress = onPress
        var pressed = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var pressedIdentifier = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &pressedIdentifier)
            guard status == noErr,
                  pressedIdentifier.signature == FixShortcutRegistration.signature,
                  pressedIdentifier.id == FixShortcutRegistration.identifier
            else { return OSStatus(eventNotHandledErr) }
            let registration = Unmanaged<FixShortcutRegistration>.fromOpaque(userData)
                .takeUnretainedValue()
            // Carbon delivers application-target events on the main thread.
            MainActor.assumeIsolated { registration.onPress() }
            return noErr
        }
        var installed: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(), callback, 1, &pressed,
            Unmanaged.passUnretained(self).toOpaque(), &installed)
        precondition(status == noErr, "InstallEventHandler failed with OSStatus \(status)")
        handler = installed
    }

    deinit {
        // The handler holds an unretained pointer to self, so it has to go
        // with it, or the next press would dereference a dangling pointer.
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    /// Replaces whatever is registered with `shortcut`. A failure is logged
    /// and kept in `registrationError`, and leaves no fix shortcut at all.
    func register(_ shortcut: HotkeyBinding) {
        precondition(shortcut.kind == .combo, "the fix shortcut is a key combination")
        unregister()
        var registered: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode), Self.carbonModifiers(for: shortcut.modifiers),
            EventHotKeyID(signature: Self.signature, id: Self.identifier),
            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &registered)
        guard status == noErr, let registered else {
            registrationError = status == OSStatus(eventHotKeyExistsErr)
                ? .taken(shortcut: shortcut.displayName)
                : .refused(shortcut: shortcut.displayName, status: status)
            Diagnostics.log("Fix shortcut \(shortcut.displayName) not registered: OSStatus \(status)")
            return
        }
        hotKey = registered
        registrationError = nil
    }

    /// While Settings records a new shortcut, so the old one's key press
    /// reaches the recorder instead of starting a fix.
    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    /// Carbon's modifier bits for the CGEventFlags a binding stores.
    nonisolated static func carbonModifiers(for flags: CGEventFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.maskCommand) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.maskShift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.maskAlternate) { modifiers |= UInt32(optionKey) }
        if flags.contains(.maskControl) { modifiers |= UInt32(controlKey) }
        return modifiers
    }
}
