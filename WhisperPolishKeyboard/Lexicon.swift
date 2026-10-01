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

    static func load() -> Lexicon {
        Lexicon(words: resource("words"), nextWords: resource("next-words"))
    }

    private static func resource(_ name: String) -> String {
        let url = Bundle.main.url(forResource: name, withExtension: "txt")!
        return try! String(contentsOf: url, encoding: .utf8)
    }

    private init(words: String, nextWords: String) {
        displayForms = words.split(separator: "\n").map(String.init)
        var ranks: [String: Int] = [:]
        for (rank, word) in displayForms.enumerated() {
            ranks[word.lowercased()] = rank
        }
        self.ranks = ranks
        let sorted = ranks.sorted { $0.key < $1.key }
        sortedWords = sorted.map(\.key)
        sortedRanks = sorted.map(\.value)

        var followers: [String: Substring] = [:]
        for line in nextWords.split(separator: "\n") {
            let tab = line.firstIndex(of: "\t")!
            followers[String(line[..<tab])] = line[line.index(after: tab)...]
        }
        self.followers = followers
    }

    func contains(_ word: String) -> Bool {
        ranks[word.lowercased()] != nil
    }

    func followers(of context: String) -> [String] {
        followers[context]?.split(separator: " ").map(String.init) ?? []
    }

    /// Words starting with `prefix`, most frequent first.
    func completions(of prefix: String, limit: Int) -> [String] {
        let prefix = prefix.lowercased()
        var low = 0
        var high = sortedWords.count
        while low < high {
            let middle = (low + high) / 2
            if sortedWords[middle] < prefix { low = middle + 1 } else { high = middle }
        }
        var matches: [Int] = []
        while low < sortedWords.count, sortedWords[low].hasPrefix(prefix) {
            matches.append(sortedRanks[low])
            low += 1
        }
        return matches.sorted().prefix(limit).map { displayForms[$0] }
    }
}
