import Foundation

/// The word being typed and the words before it in the current sentence.
struct TypingContext {
    /// How many words and sentence breaks of history the word model reads.
    static let historyLength = 48

    let partialWord: String
    let previousWords: [String]
    /// The words before the partial word, lowercased, with nil where a sentence ended.
    let history: [String?]

    init(before: String) {
        let text = before.replacingOccurrences(of: "\u{2019}", with: "'")
        let trailing = text.reversed().prefix { $0.isLetter || $0 == "'" }
        partialWord = String(String(trailing.reversed()).drop { $0 == "'" })
        let head = text.dropLast(partialWord.count)
        let sentence = head.split(omittingEmptySubsequences: false) { ".!?\n".contains($0) }.last ?? ""
        previousWords = sentence
            .split { !($0.isLetter || $0 == "'") }
            .map { $0.lowercased() }
        var history: [String?] = []
        var word = ""
        for character in head.suffix(Self.historyLength * 12) {
            if character.isLetter || character == "'" {
                word.append(character)
                continue
            }
            if !word.isEmpty {
                history.append(word.lowercased())
                word = ""
            }
            if ".!?\n".contains(character), history.last.flatMap({ $0 }) != nil {
                history.append(nil)
            }
        }
        if !word.isEmpty { history.append(word.lowercased()) }
        self.history = Array(history.suffix(Self.historyLength))
    }

    var startsSentence: Bool { previousWords.isEmpty }
}
