import UIKit

enum Autocorrect {
    private static let checker = UITextChecker()
    private static let language = "en_US"

    /// Apostrophe-free spellings people type fast; the spell checker
    /// would otherwise "fix" these into unrelated words.
    private static let contractions: [String: String] = [
        "i": "I", "im": "I'm", "ive": "I've",
        "dont": "don't", "cant": "can't", "wont": "won't", "didnt": "didn't",
        "doesnt": "doesn't", "isnt": "isn't", "wasnt": "wasn't", "arent": "aren't",
        "couldnt": "couldn't", "shouldnt": "shouldn't", "wouldnt": "wouldn't",
        "thats": "that's", "theyre": "they're", "youre": "you're", "whats": "what's",
        "theres": "there's",
    ]

    /// The word to put in place of `word`, or nil to leave it alone.
    static func correction(for word: String) -> String? {
        guard word.count >= 1, word.allSatisfy(\.isLetter) else { return nil }
        // Leave acronyms and deliberate mixed case alone.
        guard word.dropFirst().allSatisfy(\.isLowercase) else { return nil }

        let lower = word.lowercased()
        if let contraction = contractions[lower] {
            return matchCapitalization(of: word, in: contraction)
        }
        guard word.count >= 3 else { return nil }

        let range = NSRange(location: 0, length: (word as NSString).length)
        let misspelled = checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: language)
        guard misspelled.location != NSNotFound,
              let guess = checker.guesses(forWordRange: misspelled, in: word, language: language)?.first,
              !guess.contains(" ") else { return nil }
        return matchCapitalization(of: word, in: guess)
    }

    private static func matchCapitalization(of original: String, in replacement: String) -> String {
        guard original.first?.isUppercase == true else { return replacement }
        return replacement.prefix(1).uppercased() + replacement.dropFirst()
    }
}
