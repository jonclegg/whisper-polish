import Foundation

/// One word from the speech recognizer and how sure it was, 0...1.
struct TranscriptWord: Equatable {
    let text: String
    let confidence: Float

    /// Groups sub-word tokens into words. A token that starts with a space
    /// begins a new word, and a word is only as certain as its weakest piece.
    static func grouping(tokens: [(text: String, confidence: Float)]) -> [TranscriptWord] {
        var words: [TranscriptWord] = []
        var current = ""
        var confidence: Float = 1
        for token in tokens where !token.text.isEmpty {
            if token.text.first?.isWhitespace == true, !current.isEmpty {
                words.append(TranscriptWord(text: current, confidence: confidence))
                current = ""
                confidence = 1
            }
            current += token.text.trimmingCharacters(in: .whitespaces)
            confidence = min(confidence, token.confidence)
        }
        if !current.isEmpty {
            words.append(TranscriptWord(text: current, confidence: confidence))
        }
        return words
    }
}

/// A word in a transcript the recognizer was unsure about, or one that a
/// learned correction replaced. `location` and `length` are UTF-16 offsets
/// into the transcript text.
struct FlaggedWord: Codable, Equatable, Hashable {
    var location: Int
    var length: Int
    var confidence: Float
    /// What the recognizer heard, when a learned correction replaced it.
    var heard: String?

    var range: NSRange { NSRange(location: location, length: length) }
}

struct Transcript: Equatable {
    var text: String
    var flags: [FlaggedWord] = []

    /// Below this, a word is shown to the user as possibly misheard.
    static let uncertainBelow: Float = 0.5

    /// Builds a transcript from recognizer text plus per-word confidence.
    /// Uncertain words are flagged, and an uncertain word the user has
    /// corrected before is replaced with their spelling. Confident words are
    /// never replaced, so a learned correction only fills in for a mishearing.
    static func build(
        text: String,
        words: [TranscriptWord],
        corrections: PersonalCorrections = PersonalCorrections()
    ) -> Transcript {
        var output = ""
        var flags: [FlaggedWord] = []
        var copied = text.startIndex
        var searchFrom = text.startIndex

        for word in words {
            guard let found = text.range(of: word.text, range: searchFrom..<text.endIndex) else { continue }
            searchFrom = found.upperBound
            guard word.confidence < uncertainBelow,
                  let core = coreRange(of: found, in: text) else { continue }

            output += text[copied..<core.lowerBound]
            let heard = String(text[core])
            let replacement = corrections.correction(for: heard)
            let written = replacement ?? heard
            flags.append(FlaggedWord(
                location: output.utf16.count,
                length: written.utf16.count,
                confidence: word.confidence,
                heard: replacement == nil ? nil : heard
            ))
            output += written
            copied = core.upperBound
        }
        output += text[copied...]
        return Transcript(text: output, flags: flags)
    }

    /// The word without surrounding punctuation, if it has at least two letters.
    private static func coreRange(of range: Range<String.Index>, in text: String) -> Range<String.Index>? {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, !text[lower].isLetter, !text[lower].isNumber {
            lower = text.index(after: lower)
        }
        while upper > lower {
            let previous = text.index(before: upper)
            if text[previous].isLetter || text[previous].isNumber { break }
            upper = previous
        }
        guard text[lower..<upper].count >= 2 else { return nil }
        return lower..<upper
    }

    func word(for flag: FlaggedWord) -> String {
        guard flag.location >= 0, flag.length >= 0, NSMaxRange(flag.range) <= text.utf16.count else { return "" }
        return (text as NSString).substring(with: flag.range)
    }

    /// Writes `replacement` over a flagged word and clears its flag. Later
    /// flags shift so they still point at their words.
    func correcting(_ flag: FlaggedWord, to replacement: String) -> Transcript {
        guard flags.contains(flag), NSMaxRange(flag.range) <= text.utf16.count else { return self }
        let updated = (text as NSString).replacingCharacters(in: flag.range, with: replacement)
        let delta = replacement.utf16.count - flag.length
        let remaining = flags.compactMap { other -> FlaggedWord? in
            if other == flag { return nil }
            guard other.location > flag.location else { return other }
            var shifted = other
            shifted.location += delta
            return shifted
        }
        return Transcript(text: updated, flags: remaining)
    }

    /// Keeps the word as written and clears its flag.
    func accepting(_ flag: FlaggedWord) -> Transcript {
        Transcript(text: text, flags: flags.filter { $0 != flag })
    }

    /// Flagged words still in the text, for the polish prompt.
    var uncertainWords: [String] {
        var seen = Set<String>()
        return flags.map(word(for:)).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

/// Corrections the user made to misheard words, remembered on this device.
/// Like the keyboard's personal dictionary, they only apply where the
/// recognizer was unsure.
struct PersonalCorrections: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var heard: String
        var meant: String
    }

    static let maxEntries = 200

    private(set) var entries: [Entry] = []

    func correction(for heard: String) -> String? {
        let key = heard.lowercased()
        guard let entry = entries.last(where: { $0.heard == key }) else { return nil }
        return Self.matchingCase(of: heard, applied: entry.meant)
    }

    /// Remembers a fix. Choosing the original word back forgets the fix.
    mutating func learn(heard: String, meant: String) {
        let key = heard.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let value = meant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !value.isEmpty else { return }
        entries.removeAll { $0.heard == key }
        guard value.lowercased() != key else { return }
        entries.append(Entry(heard: key, meant: value))
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }

    mutating func forget(heard: String) {
        let key = heard.lowercased()
        entries.removeAll { $0.heard == key }
    }

    /// The user's spellings, newest first, for the polish prompt.
    func vocabulary(limit: Int = 40) -> [String] {
        var seen = Set<String>()
        return entries.reversed().map(\.meant)
            .filter { seen.insert($0.lowercased()).inserted }
            .prefix(limit)
            .map { $0 }
    }

    /// A lowercase learned word picks up the capital of a sentence-initial
    /// mishearing. Anything the user capitalized stays as they wrote it.
    private static func matchingCase(of heard: String, applied meant: String) -> String {
        guard let first = heard.first, first.isUppercase,
              let meantFirst = meant.first, meantFirst.isLowercase else { return meant }
        return meant.prefix(1).uppercased() + meant.dropFirst()
    }

    // MARK: - Persistence

    static func decode(_ json: String) -> PersonalCorrections {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(PersonalCorrections.self, from: data)
        else { return PersonalCorrections() }
        return decoded
    }

    func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func load(from defaults: UserDefaults = .standard) -> PersonalCorrections {
        decode(defaults.string(forKey: SettingsKeys.personalCorrections) ?? "")
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(encoded(), forKey: SettingsKeys.personalCorrections)
    }
}
