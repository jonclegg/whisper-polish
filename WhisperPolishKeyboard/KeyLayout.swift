import Foundation

enum KeyboardLayout {
    case letters
    case numbers
    case symbols
}

enum Key: Hashable {
    case character(String)
    case shift
    case delete
    case space
    case returnKey
    case nextKeyboard
    case layout(KeyboardLayout)
}

/// A key and its width in units, where a full row is `KeySpec.rowUnits` wide.
struct KeySpec: Hashable {
    static let rowUnits: CGFloat = 10

    let key: Key
    let units: CGFloat
}

extension KeyboardLayout {
    func rows(showsNextKeyboard: Bool) -> [[KeySpec]] {
        switch self {
        case .letters:
            return [
                Self.characters("qwertyuiop"),
                Self.characters("asdfghjkl"),
                [KeySpec(key: .shift, units: 1.5)] + Self.characters("zxcvbnm") + [KeySpec(key: .delete, units: 1.5)],
                Self.bottomRow(switchTo: .numbers, showsNextKeyboard: showsNextKeyboard),
            ]
        case .numbers:
            return [
                Self.characters("1234567890"),
                Self.characters("-/:;()$&@\""),
                Self.punctuationRow(switchTo: .symbols),
                Self.bottomRow(switchTo: .letters, showsNextKeyboard: showsNextKeyboard),
            ]
        case .symbols:
            return [
                Self.characters("[]{}#%^*+="),
                Self.characters("_\\|~<>€£¥•"),
                Self.punctuationRow(switchTo: .numbers),
                Self.bottomRow(switchTo: .letters, showsNextKeyboard: showsNextKeyboard),
            ]
        }
    }

    var switchLabel: String {
        switch self {
        case .letters: return "ABC"
        case .numbers: return "123"
        case .symbols: return "#+="
        }
    }

    private static func characters(_ string: String, units: CGFloat = 1) -> [KeySpec] {
        string.map { KeySpec(key: .character(String($0)), units: units) }
    }

    private static func punctuationRow(switchTo layout: KeyboardLayout) -> [KeySpec] {
        [KeySpec(key: .layout(layout), units: 1.5)]
            + characters(".,?!'", units: 1.4)
            + [KeySpec(key: .delete, units: 1.5)]
    }

    private static func bottomRow(switchTo layout: KeyboardLayout, showsNextKeyboard: Bool) -> [KeySpec] {
        var row = [KeySpec(key: .layout(layout), units: 1.25)]
        if showsNextKeyboard {
            row.append(KeySpec(key: .nextKeyboard, units: 1.25))
        }
        let returnUnits: CGFloat = 2
        let used = row.reduce(0) { $0 + $1.units } + returnUnits
        row.append(KeySpec(key: .space, units: KeySpec.rowUnits - used))
        row.append(KeySpec(key: .returnKey, units: returnUnits))
        return row
    }
}
