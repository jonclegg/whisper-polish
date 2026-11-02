import Foundation

/// What the suggestion bar offered for each word the user finished, and what they
/// ended up with, so prediction problems on the phone can be studied off it. The
/// keyboard appends while the Typing log option is on; the app summarizes, shares,
/// and clears it. It stays in the app group until the user shares it.
enum TypingLog {
    struct Entry: Codable, Equatable {
        enum Finish: String, Codable {
            /// Typed out and kept as typed.
            case typed
            /// A suggestion from the bar was tapped.
            case tapped
            /// Autocorrect replaced what was typed.
            case autocorrected
            /// The user tapped what they had typed back in place of an autocorrection.
            case reverted
        }

        /// What the bar showed once `typed` letters of the word were in.
        struct Bar: Codable, Equatable {
            let typed: String
            let shown: [String]
        }

        let date: Date
        /// The end of the text predictions read before the word began.
        let before: String
        /// The word as it ended up.
        let word: String
        let finish: Finish
        /// The letters typed before a tap or autocorrect replaced them.
        let typed: String?
        /// The bar for each prefix of the word, in the order it showed; deleted
        /// letters keep their bars, so a fixed typo shows what the bar did with it.
        let bars: [Bar]
        /// The longest the bar took to catch up with a keystroke in this word.
        let slowestBarMilliseconds: Int?
    }

    /// Under Library so `devicectl device copy from --domain-type appGroupDataContainer` can read it.
    static let fileURL = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)!
        .appendingPathComponent("Library/typing-log.jsonl")
    /// Past this the older half is dropped: about 10,000 words.
    static let maximumBytes = 8_000_000
    /// How much of the text before a word each entry keeps.
    static let contextCharacters = 240

    private static let queue = DispatchQueue(label: "TypingLog", qos: .utility)

    /// Called by the keyboard; the write happens off the main thread.
    static func append(_ entry: Entry, to url: URL = fileURL) {
        queue.async { write(entry, to: url) }
    }

    /// Waits for writes already queued, for tests.
    static func flush() {
        queue.sync {}
    }

    static func entries(at url: URL = fileURL) -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = Self.decoder
        return data.split(separator: UInt8(ascii: "\n")).map { try! decoder.decode(Entry.self, from: $0) }
    }

    static func clear(at url: URL = fileURL) {
        queue.sync { try? FileManager.default.removeItem(at: url) }
    }

    /// How the bar did over `entries`: the share of words it offered before a letter was
    /// typed, and the share of their letters (and the space after) it saved.
    struct Summary: Equatable {
        let words: Int
        let offeredBeforeTyping: Double
        let keystrokesSaved: Double
        let tapped: Int
        let autocorrected: Int
        let reverted: Int
    }

    static func summary(of entries: [Entry]) -> Summary {
        var offered = 0
        var keystrokes = 0
        var saved = 0
        for entry in entries {
            let word = entry.word.lowercased()
            keystrokes += word.count + 1
            // The first prefix of the word whose bar offered it; after a letter is in, the first slot is what's typed.
            let hit = entry.bars.first { bar in
                guard word.hasPrefix(bar.typed.lowercased()) else { return false }
                let suggestions = bar.typed.isEmpty ? bar.shown : Array(bar.shown.dropFirst())
                return suggestions.contains { $0.lowercased() == word }
            }
            if let hit {
                if hit.typed.isEmpty { offered += 1 }
                saved += word.count - hit.typed.count
            }
        }
        let count = entries.count
        return Summary(
            words: count,
            offeredBeforeTyping: count == 0 ? 0 : Double(offered) / Double(count),
            keystrokesSaved: keystrokes == 0 ? 0 : Double(saved) / Double(keystrokes),
            tapped: entries.filter { $0.finish == .tapped }.count,
            autocorrected: entries.filter { $0.finish == .autocorrected }.count,
            reverted: entries.filter { $0.finish == .reverted }.count
        )
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func write(_ entry: Entry, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var line = try! encoder.encode(entry)
        line.append(UInt8(ascii: "\n"))
        let manager = FileManager.default
        try! manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard manager.fileExists(atPath: url.path) else {
            try! line.write(to: url)
            return
        }
        let file = try! FileHandle(forUpdating: url)
        defer { try! file.close() }
        let size = try! file.seekToEnd()
        if size + UInt64(line.count) > maximumBytes {
            try! file.seek(toOffset: 0)
            let data = try! file.readToEnd() ?? Data()
            let half = data.index(data.startIndex, offsetBy: data.count / 2)
            let kept = data[half...].drop { $0 != UInt8(ascii: "\n") }.dropFirst()
            try! file.truncate(atOffset: 0)
            try! file.write(contentsOf: kept + line)
        } else {
            try! file.write(contentsOf: line)
        }
    }
}
