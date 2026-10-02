import Foundation
import UIKit

struct Suggestion: Hashable {
    let text: String
    var isQuoted = false
    var isAutocorrection = false
    var learns = false

    var title: String { isQuoted ? "\u{201C}\(text)\u{201D}" : text }
}

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

@MainActor
final class Predictor {
    struct Result {
        let suggestions: [Suggestion]
        let correction: String?
    }

    typealias Autocorrection = (original: String, replacement: String)

    private static let learnedKey = "KeyboardLearnedWords"
    private static let language = "en_US"

    /// Apostrophe-free spellings people type fast; the spell checker
    /// would otherwise "fix" these into unrelated words.
    private static let contractions: [String: String] = [
        "i": "I", "im": "I'm", "ive": "I've", "id": "I'd", "ill": "I'll",
        "dont": "don't", "cant": "can't", "wont": "won't", "didnt": "didn't",
        "doesnt": "doesn't", "isnt": "isn't", "wasnt": "wasn't", "arent": "aren't",
        "couldnt": "couldn't", "shouldnt": "shouldn't", "wouldnt": "wouldn't",
        "thats": "that's", "theyre": "they're", "youre": "you're", "whats": "what's",
        "theres": "there's", "hes": "he's", "shes": "she's",
    ]

    private let checker = UITextChecker()
    private var lexicon: Lexicon?
    private var learned: [String: String]
    private var names: Set<String> = []
    private var replacements: [String: String] = [:]

    init() {
        let words = UserDefaults.standard.stringArray(forKey: Self.learnedKey) ?? []
        learned = Dictionary(words.map { ($0.lowercased(), $0) }) { _, latest in latest }
    }

    func setLexicon(_ lexicon: Lexicon) {
        self.lexicon = lexicon
    }

    /// Contact names become known words; text replacements expand like autocorrections.
    func setSupplementaryLexicon(_ lexicon: UILexicon) {
        for entry in lexicon.entries {
            if entry.userInput.lowercased() == entry.documentText.lowercased() {
                names.insert(entry.documentText.lowercased())
            } else {
                replacements[entry.userInput.lowercased()] = entry.documentText
            }
        }
    }

    func learn(_ word: String) {
        learned[word.lowercased()] = word
        UserDefaults.standard.set(Array(learned.values), forKey: Self.learnedKey)
    }

    /// How likely each letter is to come next in the word being typed, from
    /// word frequency and the words that usually follow the previous ones.
    func letterOdds(for context: TypingContext) -> [Character: Double] {
        guard let lexicon else { return [:] }
        let prefix = context.partialWord.lowercased()
        let frequency = lexicon.nextLetterOdds(after: prefix)
        guard !frequency.isEmpty else { return [:] }
        var fromContext: [Character: Double] = [:]
        for (index, word) in context.lookupKeys.flatMap({ lexicon.followers(of: $0) }).enumerated() {
            let lower = word.lowercased()
            guard lower.hasPrefix(prefix), let letter = lower.dropFirst(prefix.count).first else { continue }
            fromContext[letter, default: 0] += 1 / Double(index + 1)
        }
        let contextual = Lexicon.normalized(fromContext)
        guard !contextual.isEmpty else { return frequency }
        return frequency.merging(contextual) { $0 + $1 }.mapValues { $0 / 2 }
    }

    /// `touches[i]` is where the i-th letter of the word being typed was touched, if known.
    func suggestions(for context: TypingContext, touches: [CGPoint?], allowsCorrection: Bool, revert: Autocorrection?) -> Result {
        guard let lexicon else { return Result(suggestions: [], correction: nil) }
        let followers = context.lookupKeys.flatMap { lexicon.followers(of: $0) }
        let typed = context.partialWord
        guard !typed.isEmpty else {
            let predictions = unique(followers).prefix(3).map {
                Suggestion(text: context.startsSentence ? Self.capitalizingFirst($0) : $0)
            }
            return Result(suggestions: Array(predictions), correction: nil)
        }

        var suggestions: [Suggestion]
        var correction: String?
        if let revert, revert.replacement == typed {
            suggestions = [Suggestion(text: revert.original, isQuoted: true, learns: true), Suggestion(text: typed)]
        } else {
            let known = isKnown(typed)
            let decoded = known ? [] : decode(typed, touches: touches, followers: followers, lexicon: lexicon)
            correction = allowsCorrection ? self.correction(for: typed, isKnown: known, decoded: decoded) : nil
            suggestions = [Suggestion(text: typed, isQuoted: !known, learns: !known)]
            if let correction {
                suggestions.append(Suggestion(text: correction, isAutocorrection: true))
            }
            for candidate in decoded where suggestions.count < 3 {
                let text = Self.matchingCase(of: typed, candidate.word)
                if !suggestions.contains(where: { $0.text.lowercased() == text.lowercased() }) {
                    suggestions.append(Suggestion(text: text))
                }
            }
        }
        let taken = Set(suggestions.map { $0.text.lowercased() })
        let completions = unique(
            followers.filter { $0.lowercased().hasPrefix(typed.lowercased()) }
                + learned.values.filter { $0.lowercased().hasPrefix(typed.lowercased()) }.sorted()
                + lexicon.completions(of: typed, limit: 6)
        )
        for completion in completions where suggestions.count < 3 && !taken.contains(completion.lowercased()) {
            suggestions.append(Suggestion(text: Self.matchingCase(of: typed, completion)))
        }
        return Result(suggestions: suggestions, correction: correction)
    }

    private func isKnown(_ word: String) -> Bool {
        let lower = word.lowercased()
        if learned[lower] != nil || names.contains(lower) || lexicon?.contains(lower) == true { return true }
        let range = NSRange(location: 0, length: (word as NSString).length)
        return checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: Self.language).location == NSNotFound
    }

    private func correction(for typed: String, isKnown: Bool, decoded: [WordDecoder.Candidate]) -> String? {
        let lower = typed.lowercased()
        if let replacement = replacements[lower] { return replacement }
        if let contraction = Self.contractions[lower], learned[lower] == nil {
            let corrected = Self.matchingCase(of: typed, contraction)
            return corrected == typed ? nil : corrected
        }
        // Leave known words, acronyms and deliberate mixed case alone.
        guard !isKnown, typed.count >= 2, !typed.dropFirst().contains(where: \.isUppercase) else { return nil }
        return decoded.first.map { Self.matchingCase(of: typed, $0.word) }
    }

    /// Words the touches most likely meant: keys near each touch, common words,
    /// and words that fit the previous ones, plus the spell checker's guesses
    /// for added or missing letters.
    private func decode(_ typed: String, touches: [CGPoint?], followers: [String], lexicon: Lexicon) -> [WordDecoder.Candidate] {
        guard typed.count >= 2 else { return [] }
        let range = NSRange(location: 0, length: (typed as NSString).length)
        let guesses = (checker.guesses(forWordRange: range, in: typed, language: Self.language) ?? [])
            .filter { !$0.contains(" ") }
        let touches = touches.count == typed.count ? touches : Array(repeating: nil, count: typed.count)
        let decoded = WordDecoder(lexicon: lexicon).candidates(typed: typed, touches: touches, likelyWords: followers, guesses: guesses)
        // Words with apostrophes have no key positions to match against.
        return decoded.isEmpty ? guesses.prefix(3).map { WordDecoder.Candidate(word: $0, score: 0) } : decoded
    }

    private func unique(_ words: [String]) -> [String] {
        var seen: Set<String> = []
        return words.filter { seen.insert($0.lowercased()).inserted }
    }

    private static func matchingCase(of typed: String, _ word: String) -> String {
        if typed.count > 1, typed.allSatisfy({ !$0.isLowercase }) { return word.uppercased() }
        if typed.first?.isUppercase == true { return capitalizingFirst(word) }
        return word
    }

    private static func capitalizingFirst(_ word: String) -> String {
        word.prefix(1).uppercased() + word.dropFirst()
    }
}
