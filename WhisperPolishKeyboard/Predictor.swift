import Foundation
import UIKit

struct Suggestion: Hashable {
    let text: String
    var isQuoted = false
    var isAutocorrection = false
    var learns = false

    var title: String { isQuoted ? "\u{201C}\(text)\u{201D}" : text }
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

    /// How much next-word odds lean on what you've typed over the word model once
    /// it has seen plenty, and how many words it takes to get halfway there.
    /// Tuned with `scripts/keyboard-model/bench.py`.
    static let personalWeight: Float = 0.45
    static let personalRamp: Float = 10_000

    private let checker = UITextChecker()
    private var lexicon: Lexicon?
    private var wordModel: WordModel?
    private var personal = PersonalModel()
    private var learned: [String: String]
    private var names: [String: String] = [:]
    private var replacements: [String: String] = [:]
    private var spellCheckedWords: [String: Bool] = [:]
    private var cachedDecoder: WordDecoder?
    var decoderSettings = WordDecoder.Settings() {
        didSet { cachedDecoder = nil }
    }
    /// Words with an apostrophe by how they're typed without it: "youve" to "you've".
    private var apostropheForms: [String: String] = [:]
    /// Every word the bar can offer: the word model's, then names and words you've taught it.
    private var vocabulary: [String: Int] = [:]
    private var vocabularyWords: [String] = []
    private var sortedVocabulary: [(word: String, id: Int)] = []
    /// The word model's memory of the history it was last fed, so each new word costs one step.
    private var modelMemory: (fed: [String?], state: WordModel.State)?
    private var cachedOdds: (history: [String?], odds: [Float])?

    init() {
        let words = UserDefaults.standard.stringArray(forKey: Self.learnedKey) ?? []
        learned = Dictionary(words.map { ($0.lowercased(), $0) }) { _, latest in latest }
    }

    /// `personal` is what was learned from your typing in earlier sessions.
    func setLexicon(_ lexicon: Lexicon, wordModel: WordModel, personal: PersonalModel = PersonalModel()) {
        self.lexicon = lexicon
        self.wordModel = wordModel
        self.personal = personal
        self.personal.addNames(Array(names.values))
        cachedDecoder = nil
        vocabulary = wordModel.ids
        vocabularyWords = wordModel.words
        sortedVocabulary = wordModel.words.enumerated().dropFirst(2).map { ($1, $0) }.sorted { $0.word < $1.word }
        apostropheForms = [:]
        for word in wordModel.words where word.contains("'") {
            let stripped = word.replacingOccurrences(of: "'", with: "")
            if apostropheForms[stripped] == nil { apostropheForms[stripped] = word }
        }
        for word in Array(learned.keys) + Array(names.keys) + personal.typed.keys.filter(personal.isLearned) {
            addToVocabulary(word)
        }
    }

    /// Contact names become known words; text replacements expand like autocorrections.
    func setSupplementaryLexicon(_ lexicon: UILexicon) {
        var names: [String] = []
        for entry in lexicon.entries {
            if entry.userInput.lowercased() == entry.documentText.lowercased() {
                names.append(entry.documentText)
            } else {
                replacements[entry.userInput.lowercased()] = entry.documentText
            }
        }
        addNames(names)
    }

    func addNames(_ names: [String]) {
        for name in names {
            self.names[name.lowercased()] = name
            addToVocabulary(name)
        }
        personal.addNames(names)
        cachedOdds = nil
    }

    func learn(_ word: String) {
        learned[word.lowercased()] = word
        UserDefaults.standard.set(Array(learned.values), forKey: Self.learnedKey)
        addToVocabulary(word)
    }

    /// Counts `word` as typed after the sentence so far; words you keep typing become suggestions.
    /// Nothing is learned until earlier sessions' learning has loaded.
    func learnTyped(_ word: String, after previous: [String]) {
        guard wordModel != nil else { return }
        personal.learn(word, after: previous)
        if personal.isLearned(word) { addToVocabulary(word) }
        cachedOdds = nil
    }

    /// What's been learned from your typing, to save between sessions.
    var personalModel: PersonalModel { personal }

    private func addToVocabulary(_ word: String) {
        let lower = word.lowercased()
        guard wordModel != nil, vocabulary[lower] == nil else { return }
        let id = vocabularyWords.count
        vocabulary[lower] = id
        vocabularyWords.append(lower)
        let position = sortedVocabulary.firstIndex { $0.word > lower } ?? sortedVocabulary.count
        sortedVocabulary.insert((lower, id), at: position)
        cachedOdds = nil
    }

    /// How likely each letter is to come next in the word being typed: the
    /// next-word odds of every word that continues it, by its next letter.
    func letterOdds(for context: TypingContext) -> [Character: Double] {
        guard let odds = nextWordOdds(for: context) else { return [:] }
        let prefix = context.partialWord.lowercased()
        var byLetter: [Character: Double] = [:]
        for index in prefixMatches(of: prefix) {
            let (word, id) = sortedVocabulary[index]
            guard word.count > prefix.count else { continue }
            let letter = word[word.index(word.startIndex, offsetBy: prefix.count)]
            if letter.isLetter { byLetter[letter, default: 0] += Double(odds[id]) }
        }
        return Lexicon.normalized(byLetter)
    }

    /// `touches[i]` is where the i-th letter of the word being typed was touched, if known.
    func suggestions(for context: TypingContext, touches: [CGPoint?], allowsCorrection: Bool, revert: Autocorrection?) -> Result {
        guard let lexicon, let odds = nextWordOdds(for: context) else { return Result(suggestions: [], correction: nil) }
        let typed = context.partialWord
        guard !typed.isEmpty else {
            let predictions = top(odds, among: 2..<vocabularyWords.count, limit: 3).map {
                Suggestion(text: context.startsSentence ? Self.capitalizingFirst(display($0)) : display($0))
            }
            return Result(suggestions: predictions, correction: nil)
        }

        var suggestions: [Suggestion]
        var correction: String?
        var decoded: [WordDecoder.Candidate] = []
        if let revert, revert.replacement == typed {
            suggestions = [Suggestion(text: revert.original, isQuoted: true, learns: true), Suggestion(text: typed)]
        } else {
            let known = isKnown(typed)
            decoded = decode(typed, touches: touches, odds: odds, lexicon: lexicon)
            correction = allowsCorrection ? self.correction(for: typed, isKnown: known, decoded: decoded, touches: touches, odds: odds) : nil
            suggestions = [Suggestion(text: typed, isQuoted: !known, learns: !known)]
            if let correction {
                suggestions.append(Suggestion(text: correction, isAutocorrection: true))
            }
            if known { decoded = [] }
        }
        // Words that finish what's typed come before other fixes for it: a partial word usually isn't a typo.
        let completions = top(odds, among: completionRange(of: typed), limit: 3).map { Self.matchingCase(of: typed, display($0)) }
        for text in completions + decoded.map({ Self.matchingCase(of: typed, $0.word) }) where suggestions.count < 3 {
            if !suggestions.contains(where: { $0.text.lowercased() == text.lowercased() }) {
                suggestions.append(Suggestion(text: text))
            }
        }
        return Result(suggestions: suggestions, correction: correction)
    }

    // MARK: - Next-word odds

    /// How likely each vocabulary word is to come next: your typing mixed with the word model.
    private func nextWordOdds(for context: TypingContext) -> [Float]? {
        guard let wordModel else { return nil }
        if let cachedOdds, cachedOdds.history == context.history { return cachedOdds.odds }
        let fromModel = wordModel.probabilities(after: modelState(after: context.history, model: wordModel))
        let count = vocabularyWords.count
        var odds = personal.probabilities(after: context.previousWords, vocabulary: vocabulary, count: count)
        // Words the model doesn't know share its unknown-word odds.
        let unknownShare = count > fromModel.count ? fromModel[WordModel.unknown] / Float(count - fromModel.count) : 0
        let learned = Float(personal.wordsTyped)
        let weight = Self.personalWeight * learned / (learned + Self.personalRamp)
        for id in 0..<count {
            odds[id] = weight * odds[id] + (1 - weight) * (id < fromModel.count ? fromModel[id] : unknownShare)
        }
        odds[WordModel.boundary] = 0
        odds[WordModel.unknown] = 0
        cachedOdds = (context.history, odds)
        return odds
    }

    /// Feeds the model only what's new since last time, unless the history changed underneath.
    private func modelState(after history: [String?], model: WordModel) -> WordModel.State {
        if let memory = modelMemory {
            for added in 0...min(3, history.count) where memory.fed.count >= history.count - added
                && Array(memory.fed.suffix(history.count - added)) == Array(history.dropLast(added)) {
                var state = memory.state
                for token in history.suffix(added) { model.advance(&state, with: token.map(model.id(of:)) ?? WordModel.boundary) }
                modelMemory = (memory.fed + history.suffix(added), state)
                return state
            }
        }
        var state = model.start
        model.advance(&state, with: WordModel.boundary)
        for token in history { model.advance(&state, with: token.map(model.id(of:)) ?? WordModel.boundary) }
        modelMemory = (history, state)
        return state
    }

    /// Ids of vocabulary words that start with `typed`, other than `typed` itself.
    private func completionRange(of typed: String) -> [Int] {
        let prefix = typed.lowercased()
        return prefixMatches(of: prefix).compactMap { sortedVocabulary[$0].word == prefix ? nil : sortedVocabulary[$0].id }
    }

    /// Positions in `sortedVocabulary` of the words starting with `prefix`.
    private func prefixMatches(of prefix: String) -> Range<Int> {
        var low = 0
        var high = sortedVocabulary.count
        while low < high {
            let middle = (low + high) / 2
            if sortedVocabulary[middle].word < prefix { low = middle + 1 } else { high = middle }
        }
        var end = low
        while end < sortedVocabulary.count, sortedVocabulary[end].word.hasPrefix(prefix) { end += 1 }
        return low..<end
    }

    private func top<Ids: Sequence>(_ odds: [Float], among ids: Ids, limit: Int) -> [Int] where Ids.Element == Int {
        var best: [Int] = []
        for id in ids where odds[id] > 0 {
            if best.count < limit {
                best.append(id)
                best.sort { odds[$0] > odds[$1] }
            } else if odds[id] > odds[best[limit - 1]] {
                best[limit - 1] = id
                best.sort { odds[$0] > odds[$1] }
            }
        }
        return best
    }

    /// How a vocabulary word is usually written: "I", "Monday", a contact's name.
    private func display(_ id: Int) -> String {
        let word = vocabularyWords[id]
        return names[word] ?? learned[word] ?? lexicon?.displayForm(of: word) ?? word
    }

    private func isKnown(_ word: String) -> Bool {
        let lower = word.lowercased()
        if learned[lower] != nil || names[lower] != nil || personal.isLearned(lower) || lexicon?.isWord(lower) == true { return true }
        // The spell checker takes any letter on its own for a word.
        if lower.count == 1 { return false }
        if let known = spellCheckedWords[lower] { return known }
        let range = NSRange(location: 0, length: (word as NSString).length)
        let known = checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: Self.language).location == NSNotFound
        if spellCheckedWords.count > 2000 { spellCheckedWords.removeAll() }
        spellCheckedWords[lower] = known
        return known
    }

    private func correction(for typed: String, isKnown: Bool, decoded: [WordDecoder.Candidate], touches: [CGPoint?], odds: [Float]) -> String? {
        let lower = typed.lowercased()
        if let replacement = replacements[lower] { return replacement }
        // Typed without its apostrophe: "youve" is "you've", and "ill" is "I'll" when the sentence says so.
        if let form = apostropheForms[lower], learned[lower] == nil, let formId = vocabulary[form],
           !isKnown || odds[formId] > decoderSettings.apostropheOddsRatio * (vocabulary[lower].map { odds[$0] } ?? 0) {
            return Self.matchingCase(of: typed, lexicon?.displayForm(of: form) ?? form)
        }
        if lower == "i" { return typed == "I" ? nil : "I" }
        // Leave acronyms, deliberate mixed case, and capital letters on their own ("plan B") alone.
        guard typed.count >= 2 || typed.first?.isLowercase == true,
              !typed.dropFirst().contains(where: \.isUppercase) else { return nil }
        guard isKnown else { return decoded.first.map { Self.matchingCase(of: typed, $0.word) } }
        // Words only the spell checker knows ("inly", "sas") are fixed when a word clearly fits better.
        if let lexicon, !lexicon.isWord(lower), learned[lower] == nil, names[lower] == nil, !personal.isLearned(lower) {
            guard let best = decoded.first,
                  let spatial = decoder(lexicon).spatialScore(typed: typed, touches: touches.count == typed.count ? touches : Array(repeating: nil, count: typed.count)),
                  best.score - (spatial + decoderSettings.oddsWeight * decoderSettings.spellCheckedLogOdds) > decoderSettings.realWordMargin else { return nil }
            return Self.matchingCase(of: typed, best.word)
        }
        // A slip that made another real word: fix it only when the touches and the sentence clearly prefer another.
        guard let lexicon, lexicon.isWord(lower),
              let best = decoded.first, !best.word.contains(" "),
              let literal = decoder(lexicon).literalScore(typed: typed, touches: touches.count == typed.count ? touches : Array(repeating: nil, count: typed.count), odds: odds),
              best.score - literal > decoderSettings.realWordMargin else { return nil }
        return Self.matchingCase(of: typed, best.word)
    }

    /// Words the touches most likely meant: keys near each touch, common words,
    /// and words that fit the previous ones.
    private func decode(_ typed: String, touches: [CGPoint?], odds: [Float], lexicon: Lexicon) -> [WordDecoder.Candidate] {
        let touches = touches.count == typed.count ? touches : Array(repeating: nil, count: typed.count)
        return decoder(lexicon).candidates(typed: typed, touches: touches, odds: odds).map { candidate in
            let words = candidate.word.split(separator: " ").map { lexicon.displayForm(of: String($0)) ?? String($0) }
            return WordDecoder.Candidate(word: words.joined(separator: " "), score: candidate.score)
        }
    }

    private func decoder(_ lexicon: Lexicon) -> WordDecoder {
        if let cachedDecoder { return cachedDecoder }
        let decoder = WordDecoder(lexicon: lexicon, settings: decoderSettings) { [vocabulary] in vocabulary[$0] }
        cachedDecoder = decoder
        return decoder
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
