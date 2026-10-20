import Foundation

extension Lexicon {
    /// The keyboard's real word lists, read straight from the repository.
    static let repository: Lexicon = {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("WhisperPolishKeyboard/Lexicon")
        return Lexicon(
            words: try! String(contentsOf: folder.appendingPathComponent("words.txt"), encoding: .utf8),
            casedAfter: try! String(contentsOf: folder.appendingPathComponent("cased-after.txt"), encoding: .utf8)
        )
    }()
}

extension WordModel {
    /// The keyboard's real word model, read straight from the repository.
    static let repository: WordModel = {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try! WordModel(contentsOf: folder.appendingPathComponent("WhisperPolishKeyboard/Lexicon/word-model.bin"))
    }()
}

extension WordDecoder {
    /// Built once, like the keyboard does, over the repository's lexicon and word model.
    static let repository = WordDecoder(lexicon: .repository, oddsIds: WordModel.repository.ids)
}

/// What a host like Messages reports before the cursor: back to the start of the
/// sentence holding the character before the cursor.
func sentenceHostReport(_ before: String) -> String {
    let characters = Array(before)
    guard !characters.isEmpty else { return "" }
    func startsSentence(_ index: Int) -> Bool {
        index == 0 || characters[index - 1] == "\n"
            || (index > 1 && characters[index - 1] == " " && ".!?".contains(characters[index - 2]))
    }
    var start = characters.count - 1
    while !startsSentence(start) { start -= 1 }
    return String(characters[start...])
}

/// A seeded generator, so every variant sees the same taps.
struct SplitMix {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    mutating func normal() -> Double {
        sqrt(-2 * log(max(uniform(), 1e-12))) * cos(2 * .pi * uniform())
    }
}

/// A tap aimed at `letter`'s key that lands `spread` key widths off on average
/// (less vertically, since rows are taller than keys are wide), and the key it lands nearest.
func sloppyTap(at letter: Character, spread: Double, random: inout SplitMix) -> (point: CGPoint, nearest: Character) {
    let center = KeyGeometry.letters.centers[letter]!
    let point = CGPoint(x: center.x + spread * random.normal(), y: center.y + spread * 0.7 * random.normal())
    let nearest = KeyGeometry.letters.centers.min { distanceSquared($0.value, point) < distanceSquared($1.value, point) }!.key
    return (point, nearest)
}

private func distanceSquared(_ a: CGPoint, _ b: CGPoint) -> Double {
    let dx = a.x - b.x
    let dy = a.y - b.y
    return dx * dx + dy * dy
}
