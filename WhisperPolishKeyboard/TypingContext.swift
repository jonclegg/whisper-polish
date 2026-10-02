import Foundation

/// The word being typed and the words before it in the current sentence.
struct TypingContext {
    let partialWord: String
    let previousWords: [String]

    init(before: String) {
        let text = before.replacingOccurrences(of: "\u{2019}", with: "'")
        let trailing = text.reversed().prefix { $0.isLetter || $0 == "'" }
        partialWord = String(String(trailing.reversed()).drop { $0 == "'" })
        let head = text.dropLast(partialWord.count)
        let sentence = head.split(omittingEmptySubsequences: false) { ".!?\n".contains($0) }.last ?? ""
        previousWords = sentence
            .split { !($0.isLetter || $0 == "'") }
            .map { $0.lowercased() }
    }

    var startsSentence: Bool { previousWords.isEmpty }

    /// Most specific context first, matching the keys in `next-words.txt`.
    var lookupKeys: [String] {
        let tokens = [Lexicon.sentenceStart] + previousWords.suffix(2)
        if tokens.count == 1 { return tokens }
        return [tokens.suffix(2).joined(separator: " "), tokens.last!]
    }
}
