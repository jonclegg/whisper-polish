import Foundation

/// Linux has no UIKit: the system word list stands in for Apple's spell checker.
final class UITextChecker {
    private static let words: Set<String> = Set(
        try! String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8).split(separator: "\n").map { $0.lowercased() }
    )

    func rangeOfMisspelledWord(in string: String, range: NSRange, startingAt: Int, wrap: Bool, language: String) -> NSRange {
        Self.words.contains(string.lowercased()) ? NSRange(location: NSNotFound, length: 0) : range
    }
}

final class UILexicon {
    var entries: [UILexiconEntry] = []
}

final class UILexiconEntry {
    var userInput = ""
    var documentText = ""
}
