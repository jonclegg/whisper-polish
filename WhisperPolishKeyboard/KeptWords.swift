import Foundation

/// Words just finished, held back from learning until they're clearly kept. A word
/// the user deletes back into, or swaps for the original after an autocorrection,
/// was a slip, and learning it would teach autocorrect to leave that slip alone.
struct KeptWords {
    struct Word: Equatable {
        let text: String
        /// The sentence before it, lowercased.
        let previous: [String]
        /// Characters between the word's end and the cursor.
        fileprivate(set) var after: Int
    }

    /// How many finished words wait before the oldest counts as kept.
    static let holding = 3

    private(set) var held: [Word] = []

    /// Holds `text`, which ends `after` characters before the cursor, and returns any word now old enough to learn.
    mutating func finished(_ text: String, previous: [String], after: Int = 0) -> [Word] {
        held.append(Word(text: text, previous: previous, after: after))
        let ready = held.count - Self.holding
        guard ready > 0 else { return [] }
        defer { held.removeFirst(ready) }
        return Array(held.prefix(ready))
    }

    mutating func typed(_ count: Int) {
        for index in held.indices { held[index].after += count }
    }

    /// Words the deletes reach into weren't kept.
    mutating func deleted(_ count: Int) {
        for index in held.indices { held[index].after -= count }
        held.removeAll { $0.after < 0 }
    }

    /// Everything held, for when the user moves on: sends the message, leaves the field, or moves the cursor.
    mutating func flush() -> [Word] {
        defer { held = [] }
        return held
    }

    /// Edits the keyboard can't follow character by character.
    mutating func drop() {
        held = []
    }
}

