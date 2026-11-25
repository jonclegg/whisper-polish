import AppKit
import SwiftUI

/// Captures a custom modifier+key combo. Uses a local NSEvent monitor rather
/// than the global tap: this only needs to see events while the settings window
/// is focused, so it needs no extra permission. What counts as a usable combo
/// is `rule`'s call, in `ShortcutRecording`.
struct ShortcutRecorderView: View {
    @Binding var binding: HotkeyBinding
    let rule: ShortcutRecording.Rule
    /// Told when recording starts and stops, however it stops, so the fix
    /// shortcut can step out of the way: while it is registered, macOS hands
    /// its key press to the hot key and the recorder never sees it.
    var onRecordingChange: (Bool) -> Void = { _ in }

    @State private var isRecording = false
    @State private var rejection: String?
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button(isRecording ? "Press a key combination…" : binding.displayName) {
                isRecording ? stop() : start()
            }
            .buttonStyle(.bordered)
            if isRecording, let rejection {
                Text(rejection).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onDisappear(perform: stop)
        // Closing Settings or clicking into another window mid-recording
        // would otherwise leave the monitor eating this app's keystrokes, and
        // the fix shortcut unregistered, with no recorder on screen to finish.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            stop()
        }
    }

    private func start() {
        isRecording = true
        rejection = nil
        onRecordingChange(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
            switch ShortcutRecording.outcome(keyCode: event.keyCode, flags: flags, rule: rule) {
            case .cancelled:
                stop()
            case let .rejected(reason):
                rejection = reason
            case let .recorded(recorded):
                binding = recorded
                stop()
            }
            return nil
        }
    }

    private func stop() {
        guard isRecording else { return }
        isRecording = false
        rejection = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onRecordingChange(false)
    }
}
