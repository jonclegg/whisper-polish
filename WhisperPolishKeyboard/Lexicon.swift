import Foundation

/// Word frequencies and next-word tables built by `scripts/build-keyboard-lexicon.py`.
struct Lexicon: Sendable {
    static let sentenceStart = "<s>"

    private let displayForms: [String]
    private let ranks: [String: Int]
    private let sortedWords: [String]
    private let sortedRanks: [Int]
    /// Context ("word" or "word word", lowercased) to space-separated followers, split on demand to keep memory low.
    private let followers: [String: Substring]
    /// Plain a–z words as bytes with their ranks, grouped by length, for matching touches key by key.
    private let wordsByLength: [Int: (words: [[UInt8]], ranks: [Int])]
    private let firstLetterOdds: [Character: Double]

    static func load() -> Lexicon {
        Lexicon(words: resource("words"), nextWords: resource("next-words"))
    }

    private static func resource(_ name: String) -> String {
        let url = Bundle.main.url(forResource: name, withExtension: "txt")!
        return try! String(contentsOf: url, encoding: .utf8)
    }

    init(words: String, nextWords: String) {
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
        let sorted = ranks.sorted { $0.key < $1.key }
        sortedWords = sorted.map(\.key)
        sortedRanks = sorted.map(\.value)

        var followers: [String: Substring] = [:]
        for line in nextWords.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            followers[String(line[..<tab])] = line[line.index(after: tab)...]
        }
        self.followers = followers
        firstLetterOdds = Self.nextLetterOdds(in: sortedWords.indices, of: sortedWords, ranks: sortedRanks, prefixLength: 0)
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

    func followers(of context: String) -> [String] {
        followers[context]?.split(separator: " ").map(String.init) ?? []
    }

    /// Words starting with `prefix`, most frequent first.
    func completions(of prefix: String, limit: Int) -> [String] {
        matches(of: prefix).map { sortedRanks[$0] }.sorted().prefix(limit).map { displayForms[$0] }
    }

    func rank(ofLowercased bytes: [UInt8]) -> Int? {
        ranks[String(decoding: bytes, as: UTF8.self)]
    }

    /// Plain a–z words of exactly `length` letters, as lowercase bytes, with their ranks.
    func words(ofLength length: Int) -> (words: [[UInt8]], ranks: [Int]) {
        wordsByLength[length] ?? ([], [])
    }

    /// How likely each letter is to come next after `prefix`, weighted by word
    /// frequency. Empty when no known word starts with `prefix`.
    func nextLetterOdds(after prefix: String) -> [Character: Double] {
        let prefix = prefix.lowercased()
        if prefix.isEmpty { return firstLetterOdds }
        return Self.nextLetterOdds(in: matches(of: prefix), of: sortedWords, ranks: sortedRanks, prefixLength: prefix.count)
    }

    private func matches(of prefix: String) -> Range<Int> {
        let prefix = prefix.lowercased()
        var low = 0
        var high = sortedWords.count
        while low < high {
            let middle = (low + high) / 2
            if sortedWords[middle] < prefix { low = middle + 1 } else { high = middle }
        }
        var end = low
        while end < sortedWords.count, sortedWords[end].hasPrefix(prefix) { end += 1 }
        return low..<end
    }

    private static func nextLetterOdds(in range: Range<Int>, of words: [String], ranks: [Int], prefixLength: Int) -> [Character: Double] {
        var odds: [Character: Double] = [:]
        for index in range {
            guard let letter = words[index].dropFirst(prefixLength).first else { continue }
            odds[letter, default: 0] += Self.weight(rank: ranks[index])
        }
        return normalized(odds)
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
