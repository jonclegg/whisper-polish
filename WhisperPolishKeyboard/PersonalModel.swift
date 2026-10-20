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
    /// How far your writing a word one way outweighs the other before the bar follows it,
    /// and how much it can build up, so a change of habit shows within a few uses.
    static let casingMargin = 2
    static let casingVotes = 6
    /// Trigrams seen once are most of the model and say the least; past this many
    /// trigrams (a year of typing makes about 60,000) they're left out of the file.
    static let maxTrigrams = 150_000

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
    /// How you write each word away from a sentence start: up for a capital, down for none.
    /// Optional so models saved before casing was learned still load.
    private var capitalVotes: [String: Int]?
    /// The capitalized way you write words, like "Rena" or "iPhone".
    private var capitalForms: [String: String]?

    init() {}

    /// Names count as known words that can start a sentence.
    mutating func addNames(_ names: [String]) {
        for name in names.map({ $0.lowercased() }) where !self.names.contains(name) {
            see(Self.sentenceStart, name)
            self.names.insert(name)
        }
    }

    /// Learns `word` as typed after `previous` (the sentence so far, lowercased).
    mutating func learn(_ word: String, after previous: [String]) {
        let written = word
        let word = word.lowercased()
        // A sentence start says nothing about how you write a word.
        if !previous.isEmpty {
            let isCapitalized = written.first?.isUppercase == true
            let votes = capitalVotes?[word, default: 0] ?? 0
            capitalVotes = capitalVotes ?? [:]
            capitalVotes![word] = min(max(votes + (isCapitalized ? 1 : -1), -Self.casingVotes), Self.casingVotes)
            if isCapitalized {
                capitalForms = capitalForms ?? [:]
                capitalForms![word] = written
            }
        }
        let context = [Self.sentenceStart] + previous.suffix(2)
        typed[word, default: 0] += 1
        wordsTyped += 1
        see(context[context.count - 1], word)
        bigrams[context[context.count - 1], default: [:]][word, default: 0] += 1
        if context.count >= 2 {
            trigrams[context.suffix(2).joined(separator: " "), default: [:]][word, default: 0] += 1
        }
    }

    /// Drops everything learned about `word`, so it stops being suggested until it's typed often again.
    mutating func forget(_ word: String) {
        let word = word.lowercased()
        typed[word] = nil
        capitalVotes?[word] = nil
        capitalForms?[word] = nil
        if let count = continuation.removeValue(forKey: word) { continuationTotal -= count }
        // Each word that followed this one was counted once for it.
        for follower in (bigrams.removeValue(forKey: word) ?? [:]).keys where follower != word {
            continuation[follower, default: 0] -= 1
            continuationTotal -= 1
        }
        for previous in bigrams.keys { bigrams[previous]?[word] = nil }
        trigrams = trigrams.filter { !$0.key.split(separator: " ").contains(Substring(word)) }
        for previous in trigrams.keys { trigrams[previous]?[word] = nil }
    }

    /// What was saved at `url`, or what an older keyboard saved as JSON at `legacy`, which
    /// is then rewritten at `url` and removed. Nothing saved yet is an empty model.
    static func load(from url: URL, migratingFrom legacy: URL) -> PersonalModel {
        if let data = try? Data(contentsOf: url) { return try! PersonalModel(file: data) }
        guard let json = try? Data(contentsOf: legacy) else { return PersonalModel() }
        let model = try! JSONDecoder().decode(PersonalModel.self, from: json)
        model.save(to: url)
        try! FileManager.default.removeItem(at: legacy)
        return model
    }

    func save(to url: URL) {
        var model = self
        model.pruneTrigrams(over: Self.maxTrigrams)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! model.file.write(to: url, options: .atomic)
    }

    /// Drops trigrams seen only once when there are more than `limit`, so years of typing
    /// don't grow the file, and the memory it's read into, without end.
    mutating func pruneTrigrams(over limit: Int) {
        guard trigrams.reduce(0, { $0 + $1.value.count }) > limit else { return }
        trigrams = trigrams.compactMapValues { followers in
            let kept = followers.filter { $0.value > 1 }
            return kept.isEmpty ? nil : kept
        }
    }

    // MARK: - File

    /// A list of every word the model mentions, then its counts with words as places in
    /// that list. A year of typing reads back about ten times faster than it did as JSON.
    private static let magic = Data("WPPM".utf8)
    private static let fileVersion: UInt32 = 1

    enum FileError: Error {
        case notAPersonalModel
        case unsupportedVersion
        case truncated
    }

    var file: Data {
        var ids: [String: UInt32] = [:]
        var words: [String] = []
        func id(_ word: String) -> UInt32 {
            if let id = ids[word] { return id }
            let id = UInt32(words.count)
            ids[word] = id
            words.append(word)
            return id
        }
        var counts = FileWriter()
        func write(_ table: [String: Int]) {
            counts.append(table.count)
            for (word, count) in table {
                counts.append(id(word))
                counts.append(count)
            }
        }
        counts.append(wordsTyped)
        counts.append(continuationTotal)
        write(typed)
        write(continuation)
        for table in [bigrams, trigrams] {
            counts.append(table.count)
            for (previous, followers) in table {
                // A trigram's context is two words; each is written as its own place in the list.
                let context = previous.split(separator: " ", omittingEmptySubsequences: false).map { id(String($0)) }
                counts.append(context.count)
                for part in context { counts.append(part) }
                write(followers)
            }
        }
        counts.append(names.count)
        for name in names { counts.append(id(name)) }
        write(capitalVotes ?? [:])
        counts.append(capitalForms?.count ?? 0)
        for (word, form) in capitalForms ?? [:] {
            counts.append(id(word))
            counts.append(id(form))
        }
        var file = FileWriter()
        file.data.append(Self.magic)
        file.append(Self.fileVersion)
        let list = Data(words.joined(separator: "\n").utf8)
        file.append(words.count)
        file.append(list.count)
        file.data.append(list)
        file.data.append(counts.data)
        return file.data
    }

    init(file data: Data) throws {
        guard data.prefix(4) == Self.magic else { throw FileError.notAPersonalModel }
        var reader = FileReader(data: data, offset: 4)
        guard try reader.unsigned() == Self.fileVersion else { throw FileError.unsupportedVersion }
        let wordCount = try reader.count()
        let words = try reader.text(bytes: reader.count()).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard words.count == wordCount || (wordCount == 0 && words == [""]) else { throw FileError.notAPersonalModel }
        func word() throws -> String {
            let id = Int(try reader.unsigned())
            guard id < words.count else { throw FileError.notAPersonalModel }
            return words[id]
        }
        func table() throws -> [String: Int] {
            let count = try reader.count()
            var table = [String: Int](minimumCapacity: count)
            for _ in 0..<count { table[try word()] = try reader.signed() }
            return table
        }
        func followers() throws -> [String: [String: Int]] {
            let count = try reader.count()
            var followers = [String: [String: Int]](minimumCapacity: count)
            for _ in 0..<count {
                let context = try (0..<reader.count()).map { _ in try word() }.joined(separator: " ")
                followers[context] = try table()
            }
            return followers
        }
        wordsTyped = try reader.signed()
        continuationTotal = try reader.signed()
        typed = try table()
        continuation = try table()
        bigrams = try followers()
        trigrams = try followers()
        names = Set(try (0..<reader.count()).map { _ in try word() })
        capitalVotes = try table()
        var forms: [String: String] = [:]
        for _ in 0..<(try reader.count()) { forms[try word()] = try word() }
        capitalForms = forms
        guard reader.isAtEnd else { throw FileError.notAPersonalModel }
    }

    /// How you write `word` mid-sentence, once you've shown a habit: a capitalized form, or the lowercase word.
    func writtenForm(of word: String) -> String? {
        let word = word.lowercased()
        let votes = capitalVotes?[word] ?? 0
        if votes >= Self.casingMargin { return capitalForms?[word] }
        if votes <= -Self.casingMargin { return word }
        return nil
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

/// Numbers as variable-length fields of seven bits a byte, low bits first, with signed
/// ones zigzagged so small negatives stay short: most counts and places take a byte or two.
private struct FileWriter {
    var data = Data()

    mutating func append(_ value: UInt32) {
        var rest = value
        while rest >= 0x80 {
            data.append(UInt8(rest & 0x7F) | 0x80)
            rest >>= 7
        }
        data.append(UInt8(rest))
    }

    mutating func append(_ value: Int) {
        let value = Int32(value)
        append(UInt32(bitPattern: (value << 1) ^ (value >> 31)))
    }
}

private struct FileReader {
    let data: Data
    var offset: Int

    var isAtEnd: Bool { offset == data.count }

    mutating func unsigned() throws -> UInt32 {
        var value: UInt32 = 0
        var shift: UInt32 = 0
        while true {
            guard offset < data.count, shift < 32 else { throw PersonalModel.FileError.truncated }
            let byte = data[data.startIndex + offset]
            offset += 1
            value |= UInt32(byte & 0x7F) << shift
            if byte < 0x80 { return value }
            shift += 7
        }
    }

    mutating func signed() throws -> Int {
        let value = try unsigned()
        return Int(Int32(bitPattern: (value >> 1) ^ (0 &- (value & 1))))
    }

    mutating func count() throws -> Int {
        let count = try signed()
        guard count >= 0 else { throw PersonalModel.FileError.notAPersonalModel }
        return count
    }

    mutating func text(bytes: Int) throws -> String {
        guard offset + bytes <= data.count else { throw PersonalModel.FileError.truncated }
        defer { offset += bytes }
        return String(decoding: data[(data.startIndex + offset)..<(data.startIndex + offset + bytes)], as: UTF8.self)
    }
}
