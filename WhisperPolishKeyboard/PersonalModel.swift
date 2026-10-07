import Foundation

/// Which words follow which in what you type, counted on the phone and never
/// sent anywhere. Mixed with the word model so suggestions lean toward your own
/// phrasing. Absolute-discount trigrams over a Kneser-Ney unigram, matching
/// `OnlinePersonal` in `scripts/keyboard-model/bench.py`.
struct PersonalModel: Codable {
    static let sentenceStart = "<s>"
    static let discount: Float = 0.75
    static let uniformShare: Float = 0.01
    /// A word you made up becomes a suggestion once you've typed it this often.
    static let timesToLearn = 2

    /// Lowercased word to times typed.
    private(set) var typed: [String: Int] = [:]
    private(set) var wordsTyped = 0
    /// How many different words each word has followed.
    private var continuation: [String: Int] = [:]
    private var continuationTotal = 0
    private var bigrams: [String: [String: Int]] = [:]
    private var trigrams: [String: [String: Int]] = [:]
    /// Names already counted as following a sentence start, which have no bigram of their own.
    private var names: Set<String> = []

    /// Names count as known words that can start a sentence.
    mutating func addNames(_ names: [String]) {
        for name in names.map({ $0.lowercased() }) where !self.names.contains(name) {
            see(Self.sentenceStart, name)
            self.names.insert(name)
        }
    }

    /// Learns `word` as typed after `previous` (the sentence so far, lowercased).
    mutating func learn(_ word: String, after previous: [String]) {
        let word = word.lowercased()
        let context = [Self.sentenceStart] + previous.suffix(2)
        typed[word, default: 0] += 1
        wordsTyped += 1
        see(context[context.count - 1], word)
        bigrams[context[context.count - 1], default: [:]][word, default: 0] += 1
        if context.count >= 2 {
            trigrams[context.suffix(2).joined(separator: " "), default: [:]][word, default: 0] += 1
        }
    }

    static func load(from url: URL) -> PersonalModel {
        guard let data = try? Data(contentsOf: url) else { return PersonalModel() }
        return try! JSONDecoder().decode(PersonalModel.self, from: data)
    }

    func save(to url: URL) {
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    func isLearned(_ word: String) -> Bool {
        typed[word.lowercased(), default: 0] >= Self.timesToLearn
    }

    /// The probability of each word in `vocabulary` coming next.
    func probabilities(after previous: [String], vocabulary: [String: Int], count: Int) -> [Float] {
        var result = [Float](repeating: Self.uniformShare / Float(count), count: count)
        if continuationTotal > 0 {
            let share = (1 - Self.uniformShare) / Float(continuationTotal)
            for (word, times) in continuation {
                if let id = vocabulary[word] { result[id] += Float(times) * share }
            }
        }
        let context = [Self.sentenceStart] + previous.suffix(2)
        if let followers = bigrams[context[context.count - 1]] {
            interpolate(&result, with: followers, vocabulary: vocabulary)
        }
        if context.count >= 2, let followers = trigrams[context.suffix(2).joined(separator: " ")] {
            interpolate(&result, with: followers, vocabulary: vocabulary)
        }
        return result
    }

    private mutating func see(_ previous: String, _ word: String) {
        if bigrams[previous]?[word] == nil, !(previous == Self.sentenceStart && names.contains(word)) {
            continuation[word, default: 0] += 1
            continuationTotal += 1
        }
    }

    private func interpolate(_ result: inout [Float], with followers: [String: Int], vocabulary: [String: Int]) {
        var known: [(id: Int, count: Int)] = []
        for (word, count) in followers {
            if let id = vocabulary[word] { known.append((id, count)) }
        }
        guard !known.isEmpty else { return }
        let total = Float(known.reduce(0) { $0 + $1.count })
        let keep = Self.discount * Float(known.count) / total
        for n in result.indices { result[n] *= keep }
        for (id, count) in known {
            result[id] += max(Float(count) - Self.discount, 0) / total
        }
    }
}
