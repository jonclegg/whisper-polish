import Foundation

enum KeyboardLayout {
    case letters
    case numbers
    case symbols
}

/// The bottom row varies with the field's keyboard type, like the system keyboard.
enum BottomRowStyle {
    case standard
    case email
    case url
    case webSearch
    case twitter
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
    func rows(bottomRow: BottomRowStyle, showsNextKeyboard: Bool) -> [[KeySpec]] {
        switch self {
        case .letters:
            return [
                Self.characters("qwertyuiop"),
                Self.characters("asdfghjkl"),
                [KeySpec(key: .shift, units: 1.5)] + Self.characters("zxcvbnm") + [KeySpec(key: .delete, units: 1.5)],
                Self.bottomRow(switchTo: .numbers, style: bottomRow, showsNextKeyboard: showsNextKeyboard),
            ]
        case .numbers:
            return [
                Self.characters("1234567890"),
                Self.characters("-/:;()$&@\""),
                Self.punctuationRow(switchTo: .symbols),
                Self.bottomRow(switchTo: .letters, style: bottomRow, showsNextKeyboard: showsNextKeyboard),
            ]
        case .symbols:
            return [
                Self.characters("[]{}#%^*+="),
                Self.characters("_\\|~<>€£¥•"),
                Self.punctuationRow(switchTo: .numbers),
                Self.bottomRow(switchTo: .letters, style: bottomRow, showsNextKeyboard: showsNextKeyboard),
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

    private static func bottomRow(switchTo layout: KeyboardLayout, style: BottomRowStyle, showsNextKeyboard: Bool) -> [KeySpec] {
        var leading = [KeySpec(key: .layout(layout), units: 1.25)]
        if showsNextKeyboard {
            leading.append(KeySpec(key: .nextKeyboard, units: 1.25))
        }
        let returnKey = KeySpec(key: .returnKey, units: 2)
        let remaining = KeySpec.rowUnits - leading.reduce(0) { $0 + $1.units } - returnKey.units
        let extras: [String] = switch style {
        case .standard: []
        case .email: ["@", "."]
        case .webSearch: ["."]
        case .twitter: ["@", "#"]
        case .url: [".", "/", ".com"]
        }
        if style == .url {
            let width = remaining / CGFloat(extras.count)
            return leading + extras.map { KeySpec(key: .character($0), units: width) } + [returnKey]
        }
        let space = KeySpec(key: .space, units: remaining - CGFloat(extras.count))
        return leading + [space] + extras.map { KeySpec(key: .character($0), units: 1) } + [returnKey]
    }
}

enum Accents {
    private static let variants: [String: [String]] = [
        "a": ["à", "á", "â", "ä", "æ", "ã", "å", "ā"],
        "c": ["ç", "ć", "č"],
        "e": ["è", "é", "ê", "ë", "ē", "ė", "ę"],
        "i": ["î", "ï", "í", "ī", "į", "ì"],
        "l": ["ł"],
        "n": ["ñ", "ń"],
        "o": ["ô", "ö", "ò", "ó", "œ", "ø", "ō", "õ"],
        "s": ["ß", "ś", "š"],
        "u": ["û", "ü", "ù", "ú", "ū"],
        "y": ["ÿ"],
        "z": ["ž", "ź", "ż"],
        "-": ["–", "—", "•"],
        "/": ["\\"],
        "$": ["₽", "¥", "€", "¢", "£", "₩"],
        "&": ["§"],
        "\"": ["„", "“", "”", "»", "«"],
        ".": ["…"],
        "?": ["¿"],
        "!": ["¡"],
        "'": ["`", "‘", "’"],
        "0": ["°"],
        "%": ["‰"],
        ".com": [".net", ".org", ".edu", ".us", ".co.uk"],
    ]

    /// Choices shown when the key is held, starting with the key itself.
    static func choices(for character: String) -> [String] {
        guard let variants = variants[character] else { return [] }
        return [character] + variants
    }
}
