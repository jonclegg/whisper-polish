import CoreGraphics
import Foundation

/// Virtual key codes for the modifier keys we can bind. flagsChanged events
/// carry the code of the physical key that changed, which is the only way to
/// tell left from right (the flag masks themselves are side-agnostic).
enum ModifierKeyCode {
    static let rightCommand: UInt16 = 54
    static let leftCommand: UInt16 = 55
    static let leftShift: UInt16 = 56
    static let leftOption: UInt16 = 58
    static let rightOption: UInt16 = 61
    static let rightShift: UInt16 = 60
    static let leftControl: UInt16 = 59
    static let rightControl: UInt16 = 62
    static let fn: UInt16 = 63

    /// The device-independent flag that appears when this key goes down.
    static func mask(for keyCode: UInt16) -> CGEventFlags? {
        switch keyCode {
        case rightCommand, leftCommand: return .maskCommand
        case leftShift, rightShift: return .maskShift
        case leftOption, rightOption: return .maskAlternate
        case leftControl, rightControl: return .maskControl
        case fn: return .maskSecondaryFn
        default: return nil
        }
    }
}

/// Hashable because SwiftUI's hotkey Picker tags rows with binding values.
struct HotkeyBinding: Codable, Equatable, Hashable {
    enum Kind: String, Codable {
        case modifierOnly
        case combo
    }

    let kind: Kind
    let keyCode: UInt16
    /// Raw CGEventFlags bits. Empty for modifier-only bindings.
    let modifierBits: UInt64

    var modifiers: CGEventFlags { CGEventFlags(rawValue: modifierBits) }
    var isModifierOnly: Bool { kind == .modifierOnly }

    static let rightOption = HotkeyBinding(
        kind: .modifierOnly, keyCode: ModifierKeyCode.rightOption, modifierBits: 0)
    static let rightCommand = HotkeyBinding(
        kind: .modifierOnly, keyCode: ModifierKeyCode.rightCommand, modifierBits: 0)
    static let fn = HotkeyBinding(
        kind: .modifierOnly, keyCode: ModifierKeyCode.fn, modifierBits: 0)

    /// The fix shortcut out of the box: ⌘⇧1, the shortcut the Fixit app
    /// uses, so the habit carries over. 18 is the "1" key.
    static let defaultFixShortcut = HotkeyBinding(
        comboKeyCode: 18, modifiers: [.maskCommand, .maskShift])

    init(kind: Kind, keyCode: UInt16, modifierBits: UInt64) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifierBits = modifierBits
    }

    init(comboKeyCode: UInt16, modifiers: CGEventFlags) {
        self.init(kind: .combo, keyCode: comboKeyCode, modifierBits: modifiers.rawValue)
    }

    var displayName: String {
        switch kind {
        case .modifierOnly:
            switch keyCode {
            case ModifierKeyCode.rightOption: return "Right ⌥"
            case ModifierKeyCode.rightCommand: return "Right ⌘"
            case ModifierKeyCode.fn: return "fn"
            default: return "Key \(keyCode)"
            }
        case .combo:
            var name = ""
            if modifiers.contains(.maskControl) { name += "⌃" }
            if modifiers.contains(.maskAlternate) { name += "⌥" }
            if modifiers.contains(.maskShift) { name += "⇧" }
            if modifiers.contains(.maskCommand) { name += "⌘" }
            return name + KeyCodeNames.name(for: keyCode)
        }
    }
}

/// Names for virtual key codes as a US keyboard labels them. A fixed table
/// rather than a lookup through the current keyboard layout: the codes are
/// physical positions, so on another layout a letter may show its US name,
/// but the table never depends on which input source happens to be active
/// when Settings is drawn.
enum KeyCodeNames {
    private static let names: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
        34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",", 47: ".",
        44: "/", 50: "`",
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape", 117: "Forward Delete",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4",
        87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7", 91: "Keypad 8", 92: "Keypad 9",
        65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 75: "Keypad /", 78: "Keypad -",
        81: "Keypad =", 76: "Enter", 71: "Clear",
    ]

    static func name(for keyCode: UInt16) -> String {
        names[keyCode] ?? "Key \(keyCode)"
    }
}
