import CoreGraphics
import Foundation

/// What a key press means to `ShortcutRecorderView` while it is recording.
/// Pure, so the accept/reject rule is tested rather than clicked through.
enum ShortcutRecording {
    enum Outcome: Equatable {
        /// Escape: stop recording and keep the shortcut as it was.
        case cancelled
        /// Not usable; recording carries on and shows why.
        case rejected(String)
        case recorded(HotkeyBinding)
    }

    struct Rule {
        /// Modifiers kept from the press. Anything else on the event (caps
        /// lock, and the fn bit macOS sets on arrows and F-keys) is dropped.
        let allowedModifiers: CGEventFlags
        /// At least one of these has to be held.
        let requiredModifiers: CGEventFlags
        /// Shown when none of `requiredModifiers` was held.
        let requirement: String

        /// The hold-to-talk combo is matched by HotkeyMonitor's event tap,
        /// which can tell fn apart, so any modifier will do.
        static let dictation = Rule(
            allowedModifiers: HotkeyMatcher.relevantMasks,
            requiredModifiers: HotkeyMatcher.relevantMasks,
            requirement: "Hold a modifier key with the key.")

        /// The fix shortcut is a Carbon hot key, which has no fn modifier.
        /// Shift alone is not enough because ⇧ plus a key is how a capital
        /// letter or a symbol gets typed, so the shortcut would eat ordinary
        /// typing in every app.
        static let fixShortcut = Rule(
            allowedModifiers: [.maskCommand, .maskShift, .maskAlternate, .maskControl],
            requiredModifiers: [.maskCommand, .maskAlternate, .maskControl],
            requirement: "Hold ⌘, ⌃ or ⌥ with the key. ⇧ alone is not enough.")
    }

    static let escapeKeyCode: UInt16 = 53

    static func outcome(keyCode: UInt16, flags: CGEventFlags, rule: Rule) -> Outcome {
        if keyCode == escapeKeyCode { return .cancelled }
        // A modifier key on its own; the recorder wants the key it is held with.
        if ModifierKeyCode.mask(for: keyCode) != nil {
            return .rejected("Press a key along with the modifiers.")
        }
        let modifiers = flags.intersection(rule.allowedModifiers)
        guard !modifiers.isDisjoint(with: rule.requiredModifiers) else {
            return .rejected(rule.requirement)
        }
        return .recorded(HotkeyBinding(comboKeyCode: keyCode, modifiers: modifiers))
    }
}
