import Foundation

/// The text before the cursor, reaching back past what the host reports. Hosts
/// share only the sentence the cursor is in, but the word model predicts better
/// from the whole message, so earlier sentences are remembered as they go by.
struct ContextMemory {
    /// About as much as the word model reads.
    static let length = 600

    private var document: UUID?
    /// Typing never changes the text after the cursor, so a different report means the cursor moved.
    private var after = ""
    private(set) var text = ""

    /// `before` with what's remembered ahead of it. The host's report always wins
    /// where the two disagree; only the sentences before it come from memory.
    mutating func extend(_ before: String, after: String, document: UUID?) -> String {
        // A new field, a moved cursor, or a field emptied after sending a message starts over.
        if document != self.document || after != self.after || (before.isEmpty && after.isEmpty) {
            self.document = document
            self.after = after
            text = String(before.suffix(Self.length))
            return text
        }
        if !text.hasSuffix(before) {
            // Hosts report from a sentence start, so line the report up with the earliest
            // remembered sentence it continues, else with the last one, deleted back into.
            let starts = Self.sentenceStarts(in: text)
            let continued = starts.first { before.hasPrefix(text[$0...]) }
            let deleted = starts.last { $0 < text.endIndex }.flatMap { text[$0...].hasPrefix(before) ? $0 : nil }
            text = (continued ?? deleted).map { String(text[..<$0]) + before } ?? before
        }
        text = String(text.suffix(Self.length))
        return text
    }

    /// Where sentences start in `text`: its start, after a line break, and after
    /// sentence-ending punctuation and a space, in order.
    private static func sentenceStarts(in text: String) -> [String.Index] {
        var starts = [text.startIndex]
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            index = text.index(after: index)
            if character == "\n" {
                starts.append(index)
            } else if ".!?".contains(character), index < text.endIndex, text[index] == " " {
                while index < text.endIndex, text[index] == " " { index = text.index(after: index) }
                starts.append(index)
            }
        }
        return starts
    }
}
