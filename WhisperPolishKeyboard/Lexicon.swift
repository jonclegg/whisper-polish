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
    /// Ranks of plain a–z words, grouped by length, for matching touches key by key.
    private let ranksByLength: [Int: [Int]]
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
        var ranksByLength: [Int: [Int]] = [:]
        for (rank, word) in displayForms.enumerated() {
            let lower = word.lowercased()
            if ranks[lower] == nil {
                ranks[lower] = rank
                if lower.allSatisfy({ $0 >= "a" && $0 <= "z" }) {
                    ranksByLength[lower.count, default: []].append(rank)
                }
            }
        }
        self.ranks = ranks
        self.ranksByLength = ranksByLength
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

    /// Plain a–z words of exactly `length` letters, lowercased, with their ranks.
    func words(ofLength length: Int) -> [(word: String, rank: Int)] {
        (ranksByLength[length] ?? []).map { (displayForms[$0].lowercased(), $0) }
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
