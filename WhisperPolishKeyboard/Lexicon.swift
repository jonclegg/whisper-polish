import Foundation

/// The keyboard's word list by frequency, built by `scripts/build-keyboard-lexicon.py`.
/// The word model's vocabulary is this list, so changing it means retraining the model.
struct Lexicon: Sendable {
    private let displayForms: [String]
    private let ranks: [String: Int]
    /// Plain a–z words as bytes with their ranks, grouped by length, for matching touches key by key.
    private let wordsByLength: [Int: (words: [[UInt8]], ranks: [Int])]

    static func load() -> Lexicon {
        Lexicon(words: try! String(contentsOf: Bundle.main.url(forResource: "words", withExtension: "txt")!, encoding: .utf8))
    }

    init(words: String) {
        displayForms = words.split(separator: "\n").map(String.init)
        var ranks: [String: Int] = [:]
        var wordsByLength: [Int: (words: [[UInt8]], ranks: [Int])] = [:]
        for (rank, word) in displayForms.enumerated() {
            let lower = word.lowercased()
            if ranks[lower] == nil {
                ranks[lower] = rank
                let bytes = Array(lower.utf8)
                if bytes.allSatisfy({ $0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z") }) {
                    wordsByLength[bytes.count, default: ([], [])].words.append(bytes)
                    wordsByLength[bytes.count, default: ([], [])].ranks.append(rank)
                }
            }
        }
        self.ranks = ranks
        self.wordsByLength = wordsByLength
    }

    func contains(_ word: String) -> Bool {
        ranks[word.lowercased()] != nil
    }

    /// Whether `word` is a real word rather than one of the list's fragments.
    func isWord(_ word: String) -> Bool {
        let lower = word.lowercased()
        guard let rank = ranks[lower] else { return false }
        return Self.isWord(Array(lower.utf8), rank: rank)
    }

    /// The list counts every letter and plenty of short fragments ("el", "co",
    /// "thr") as words, so short words only count when they're real and common.
    static func isWord(_ word: [UInt8], rank: Int) -> Bool {
        switch word.count {
        case 1: word == [UInt8(ascii: "a")] || word == [UInt8(ascii: "i")]
        case 2: twoLetterWords.contains(String(decoding: word, as: UTF8.self))
        case 3: rank < 10_000
        default: true
        }
    }

    private static let twoLetterWords: Set<String> = [
        "ah", "am", "an", "as", "at", "be", "by", "do", "eh", "go", "ha", "he", "hi", "hm", "if", "in", "is", "it",
        "me", "mm", "my", "no", "of", "oh", "ok", "on", "or", "ow", "so", "to", "uh", "um", "up", "us", "we", "ya", "yo",
    ]

    /// How the word is usually written, like "I" or "Monday".
    func displayForm(of word: String) -> String? {
        ranks[word.lowercased()].map { displayForms[$0] }
    }

    /// 0 is the most common word; nil for words outside the list.
    func rank(of word: String) -> Int? {
        ranks[word.lowercased()]
    }

    func rank(ofLowercased bytes: [UInt8]) -> Int? {
        ranks[String(decoding: bytes, as: UTF8.self)]
    }

    /// Plain a–z words of exactly `length` letters, as lowercase bytes, with their ranks.
    func words(ofLength length: Int) -> (words: [[UInt8]], ranks: [Int]) {
        wordsByLength[length] ?? ([], [])
    }

    /// Roughly Zipf: a word's share of running text falls off with its rank.
    static func weight(rank: Int) -> Double {
        1 / Double(rank + 100)
    }

    static func normalized(_ odds: [Character: Double]) -> [Character: Double] {
        let total = odds.values.reduce(0, +)
        guard total > 0 else { return [:] }
        return odds.mapValues { $0 / total }
    }
}
