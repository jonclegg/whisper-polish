import Foundation
import UIKit

struct Suggestion: Hashable {
    let text: String
    var isQuoted = false
    var isAutocorrection = false
    var learns = false

    var title: String { isQuoted ? "\u{201C}\(text)\u{201D}" : text }
}

/// Not thread-safe: the keyboard only touches it on `PredictionEngine`'s queue.
final class Predictor: @unchecked Sendable {
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

    /// The spell checker loads its dictionaries on first use, long enough to stall a keystroke.
    nonisolated static func warmUpSpellChecker() {
        _ = UITextChecker().rangeOfMisspelledWord(in: "warm", range: NSRange(location: 0, length: 4), startingAt: 0, wrap: false, language: language)
    }
    private var lexicon: Lexicon?
    private var wordModel: WordModel?
    private var personal = PersonalModel()
    private var learned: [String: String]
    private var names: [String: String] = [:]
    private var replacements: [String: String] = [:]
    private var spellCheckedWords: [String: Bool] = [:]
    private var slipsChecked: [String: Bool] = [:]
    private var decoder: WordDecoder?
    var decoderSettings = WordDecoder.Settings() {
        didSet { decoder?.settings = decoderSettings }
    }
    /// Words with an apostrophe by how they're typed without it: "youve" to "you've".
    private var apostropheForms: [String: String] = [:]
    /// Every word the bar can offer: the word model's, then names and words you've taught it.
    private var vocabulary: [String: Int] = [:]
    private var vocabularyWords: [String] = []
    private var sortedVocabulary: [(bytes: [UInt8], id: Int)] = []
    /// The word model's state after each word it was fed, `states[i]` following `fed[..<i]`, so a
    /// new word costs one step and going back (a backspace across a space, a cursor move) costs
    /// none. `fresh` while `fed` still starts where the model started, at a sentence boundary.
    private var modelMemory: (fed: [String?], states: [WordModel.State], fresh: Bool)?
    /// About 8 KB each.
    private static let rememberedStates = 2 * TypingContext.historyLength
    private var cachedOdds: (history: [String?], odds: [Float])?
    /// Words the last call fed the word model: none or one while typing, the whole history after a jump.
    private(set) var lastModelSteps = 0

    init() {
        let words = UserDefaults.standard.stringArray(forKey: Self.learnedKey) ?? []
        learned = Dictionary(words.map { ($0.lowercased(), $0) }) { _, latest in latest }
    }

    /// `personal` is what was learned from your typing in earlier sessions. `decoder`
    /// reads only the lexicon and the word model, so it's built once per process.
    func setLexicon(_ lexicon: Lexicon, wordModel: WordModel, decoder: WordDecoder, personal: PersonalModel = PersonalModel()) {
        self.lexicon = lexicon
        self.wordModel = wordModel
        self.decoder = decoder
        self.decoder!.settings = decoderSettings
        self.personal = personal
        self.personal.addNames(Array(names.values))
        apostropheForms = wordModel.apostropheForms
        rebuildVocabulary()
    }

    var isLoaded: Bool { wordModel != nil }

    /// The word model's words, then names and words you've taught it.
    private func rebuildVocabulary() {
        guard let wordModel else { return }
        cachedOdds = nil
        vocabulary = wordModel.ids
        vocabularyWords = wordModel.words
        sortedVocabulary = wordModel.sortedWords
        addToVocabulary(Array(learned.keys) + Array(names.keys) + personal.typed.keys.filter(isLearnedTyped))
    }

    /// Words the keyboard added to its dictionary on its own: ones you kept from
    /// the bar, and made-up words you typed often enough. Not real words or names.
    var learnedWords: [String] {
        guard let wordModel, let lexicon else { return [] }
        let typed = personal.typed.keys.filter {
            isLearnedTyped($0) && wordModel.ids[$0] == nil && !lexicon.isWord($0) && learned[$0] == nil
        }
        return Array(learned.values) + typed.filter { names[$0] == nil }
    }

    /// Forgets words you removed in the app. Needs earlier sessions' learning loaded, or it would come back.
    func forget(_ words: [String]) {
        precondition(isLoaded, "Forgetting before the personal model loads would be undone when it does")
        guard !words.isEmpty else { return }
        for word in words {
            learned[word.lowercased()] = nil
            personal.forget(word)
        }
        UserDefaults.standard.set(Array(learned.values), forKey: Self.learnedKey)
        rebuildVocabulary()
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
        for name in names { self.names[name.lowercased()] = name }
        addToVocabulary(names)
        personal.addNames(names)
        cachedOdds = nil
    }

    func learn(_ word: String) {
        learned[word.lowercased()] = word
        UserDefaults.standard.set(Array(learned.values), forKey: Self.learnedKey)
        addToVocabulary([word])
    }

    /// Counts `word` as typed after the sentence so far; words you keep typing become suggestions.
    /// Nothing is learned until earlier sessions' learning has loaded.
    func learnTyped(_ word: String, after previous: [String]) {
        guard wordModel != nil else { return }
        personal.learn(word, after: previous)
        if isLearnedTyped(word) { addToVocabulary([word]) }
        cachedOdds = nil
    }

    /// What's been learned from your typing, to save between sessions.
    var personalModel: PersonalModel { personal }

    /// Made-up words one slip from a common word ("teh", "becuase") are likelier typos
    /// than words of your own, so they take this many typings to learn, not two.
    static let timesToLearnSlip = 4
    /// Words this common are the ones a slip would most likely have been meant as.
    private static let commonRank = 10_000

    /// Whether you've typed `word` often enough for the keyboard to take it as a word.
    private func isLearnedTyped(_ word: String) -> Bool {
        let lower = word.lowercased()
        let times = personal.typed[lower, default: 0]
        guard times >= PersonalModel.timesToLearn else { return false }
        return times >= Self.timesToLearnSlip || !isSlipOfCommonWord(lower)
    }

    /// Whether one dropped, added, swapped, or wrong letter makes `word` (lowercased) a common word.
    private func isSlipOfCommonWord(_ word: String) -> Bool {
        if let known = slipsChecked[word] { return known }
        guard let lexicon else { return false }
        let letters = Array(word.utf8)
        let alphabet = UInt8(ascii: "a")...UInt8(ascii: "z")
        func isCommon(_ candidate: [UInt8]) -> Bool {
            guard let rank = lexicon.rank(ofLowercased: candidate) else { return false }
            return rank < Self.commonRank && Lexicon.isWord(candidate, rank: rank)
        }
        func search() -> Bool {
            guard letters.count >= 3, letters.allSatisfy(alphabet.contains), !lexicon.isWord(word) else { return false }
            for index in letters.indices {
                var dropped = letters
                dropped.remove(at: index)
                if isCommon(dropped) { return true }
                if index > 0 {
                    var swapped = letters
                    swapped.swapAt(index, index - 1)
                    if isCommon(swapped) { return true }
                }
                for letter in alphabet where letter != letters[index] {
                    var changed = letters
                    changed[index] = letter
                    if isCommon(changed) { return true }
                }
            }
            for index in 0...letters.count {
                for letter in alphabet {
                    var added = letters
                    added.insert(letter, at: index)
                    if isCommon(added) { return true }
                }
            }
            return false
        }
        let isSlip = search()
        slipsChecked[word] = isSlip
        return isSlip
    }

    /// New words are sorted among themselves and merged in, one pass however many
    /// there are: a keyboard opening adds every name and learned word.
    private func addToVocabulary(_ words: [String]) {
        guard wordModel != nil else { return }
        var added: [(bytes: [UInt8], id: Int)] = []
        for word in words {
            let lower = word.lowercased()
            guard vocabulary[lower] == nil else { continue }
            let id = vocabularyWords.count
            vocabulary[lower] = id
            vocabularyWords.append(lower)
            added.append((Array(lower.utf8), id))
        }
        guard !added.isEmpty else { return }
        added.sort { $0.bytes.lexicographicallyPrecedes($1.bytes) }
        var merged: [(bytes: [UInt8], id: Int)] = []
        merged.reserveCapacity(sortedVocabulary.count + added.count)
        var next = 0
        for entry in sortedVocabulary {
            while next < added.count, added[next].bytes.lexicographicallyPrecedes(entry.bytes) {
                merged.append(added[next])
                next += 1
            }
            merged.append(entry)
        }
        merged += added[next...]
        sortedVocabulary = merged
        cachedOdds = nil
    }

    /// How likely each letter is to come next in the word being typed: the
    /// next-word odds of every word that continues it, by its next letter.
    func letterOdds(for context: TypingContext) -> [Character: Double] {
        guard let odds = nextWordOdds(for: context) else { return [:] }
        let prefix = Array(context.partialWord.lowercased().utf8)
        var byLetter = [Double](repeating: 0, count: 26)
        for index in prefixMatches(of: prefix) {
            let (word, id) = sortedVocabulary[index]
            guard word.count > prefix.count else { continue }
            let letter = Int(word[prefix.count]) - Int(UInt8(ascii: "a"))
            if letter >= 0, letter < 26 { byLetter[letter] += Double(odds[id]) }
        }
        var result: [Character: Double] = [:]
        for (letter, odds) in byLetter.enumerated() where odds > 0 {
            result[Character(Unicode.Scalar(UInt8(ascii: "a") + UInt8(letter)))] = odds
        }
        return Lexicon.normalized(result)
    }

    /// `touches[i]` is where the i-th letter of the word being typed was touched, if known.
    func suggestions(for context: TypingContext, touches: [CGPoint?], allowsCorrection: Bool, revert: Autocorrection?) -> Result {
        guard let lexicon, let odds = nextWordOdds(for: context) else { return Result(suggestions: [], correction: nil) }
        let typed = context.partialWord
        guard !typed.isEmpty else {
            let predictions = top(odds, among: 2..<vocabularyWords.count, limit: 3).map {
                Suggestion(text: context.startsSentence ? Self.capitalizingFirst(display($0, after: nil)) : display($0, after: context.previousWords.last))
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
        let completions = top(odds, among: completionRange(of: typed), limit: 3).map {
            Self.matchingCase(of: typed, display($0, after: context.previousWords.last))
        }
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
        lastModelSteps = 0
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

    /// Feeds the model only what it hasn't seen: it resumes from the longest stretch of
    /// `history` it was already fed. Anything else, like a different text field, starts over.
    private func modelState(after history: [String?], model: WordModel) -> WordModel.State {
        var fed: [String?] = []
        var states: [WordModel.State]
        var fresh = true
        var matched = 0
        if let memory = modelMemory, let resume = Self.resumePoint(of: history, in: memory.fed, fresh: memory.fresh) {
            // Looking back, as after a backspace or a cursor move, keeps what comes after for coming back.
            guard resume.matched < history.count else {
                lastModelSteps = 0
                return memory.states[resume.end]
            }
            fed = Array(memory.fed[..<resume.end])
            states = Array(memory.states[...resume.end])
            fresh = memory.fresh
            matched = resume.matched
            lastModelSteps = history.count - matched
        } else {
            var state = model.start
            model.advance(&state, with: WordModel.boundary)
            states = [state]
            lastModelSteps = history.count + 1
        }
        for token in history[matched...] {
            var state = states[states.count - 1]
            model.advance(&state, with: token.map(model.id(of:)) ?? WordModel.boundary)
            fed.append(token)
            states.append(state)
        }
        if fed.count > Self.rememberedStates {
            fed.removeFirst(fed.count - Self.rememberedStates)
            states.removeFirst(states.count - Self.rememberedStates - 1)
            fresh = false
        }
        modelMemory = (fed, states, fresh)
        return states[states.count - 1]
    }

    /// Where in `fed` to pick `history` up: `matched` of its words were fed, ending at `fed[end - 1]`.
    /// A history shorter than the limit is the whole text, so it lines up only with the start
    /// of what was fed; a full one is a window on longer text, so it can line up anywhere,
    /// as long as most of it was fed.
    private static func resumePoint(of history: [String?], in fed: [String?], fresh: Bool) -> (end: Int, matched: Int)? {
        guard history.count == TypingContext.historyLength else {
            guard fresh else { return nil }
            let matched = zip(fed, history).prefix { $0 == $1 }.count
            return (matched, matched)
        }
        var best: (end: Int, matched: Int)?
        for offset in fed.indices {
            let matched = zip(fed[offset...], history).prefix { $0 == $1 }.count
            if matched >= history.count / 2, matched >= best?.matched ?? 0 { best = (offset + matched, matched) }
        }
        return best
    }

    /// Ids of vocabulary words that start with `typed`, other than `typed` itself.
    private func completionRange(of typed: String) -> [Int] {
        let prefix = Array(typed.lowercased().utf8)
        return prefixMatches(of: prefix).compactMap { sortedVocabulary[$0].bytes == prefix ? nil : sortedVocabulary[$0].id }
    }

    /// Positions in `sortedVocabulary` of the words starting with `prefix`.
    private func prefixMatches(of prefix: [UInt8]) -> Range<Int> {
        var low = 0
        var high = sortedVocabulary.count
        while low < high {
            let middle = (low + high) / 2
            if sortedVocabulary[middle].bytes.lexicographicallyPrecedes(prefix) { low = middle + 1 } else { high = middle }
        }
        var end = low
        while end < sortedVocabulary.count, sortedVocabulary[end].bytes.starts(with: prefix) { end += 1 }
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

    private func display(_ id: Int, after previous: String?) -> String {
        written(vocabularyWords[id], after: previous)
    }

    /// How the bar writes `word` (lowercased) mid-sentence after `previous`: capitalized where
    /// that word makes it a name ("in May"), else the way you write it, else a word you
    /// taught it, else the word list's form ("I", "Monday"). A contact's capitals only
    /// count for words that aren't everyday words, since contacts are split into words
    /// and business names turn "for" or "time" into names.
    func written(_ word: String, after previous: String?) -> String {
        if let previous, let named = lexicon?.capitalizedForm(of: word, after: previous) { return named }
        if let written = personal.writtenForm(of: word) { return written }
        if let learned = learned[word] { return learned }
        let listed = lexicon?.displayForm(of: word)
        if let name = names[word], listed == nil || listed != word { return name }
        return listed ?? word
    }

    private func isKnown(_ word: String) -> Bool {
        let lower = word.lowercased()
        if learned[lower] != nil || names[lower] != nil || isLearnedTyped(lower) || lexicon?.isWord(lower) == true { return true }
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
        if let lexicon, !lexicon.isWord(lower), learned[lower] == nil, names[lower] == nil, !isLearnedTyped(lower) {
            guard let best = decoded.first,
                  let spatial = decoder!.spatialScore(typed: typed, touches: touches.count == typed.count ? touches : Array(repeating: nil, count: typed.count)),
                  best.score - (spatial + decoderSettings.oddsWeight * decoderSettings.spellCheckedLogOdds) > decoderSettings.realWordMargin else { return nil }
            return Self.matchingCase(of: typed, best.word)
        }
        // A slip that made another real word: fix it only when the touches and the sentence clearly prefer another.
        guard let lexicon, lexicon.isWord(lower),
              let best = decoded.first, !best.word.contains(" "),
              let literal = decoder!.literalScore(typed: typed, touches: touches.count == typed.count ? touches : Array(repeating: nil, count: typed.count), oddsId: vocabulary[lower], odds: odds),
              best.score - literal > decoderSettings.realWordMargin else { return nil }
        return Self.matchingCase(of: typed, best.word)
    }

    /// Words the touches most likely meant: keys near each touch, common words,
    /// and words that fit the previous ones.
    private func decode(_ typed: String, touches: [CGPoint?], odds: [Float], lexicon: Lexicon) -> [WordDecoder.Candidate] {
        let touches = touches.count == typed.count ? touches : Array(repeating: nil, count: typed.count)
        return decoder!.candidates(typed: typed, touches: touches, odds: odds).map { candidate in
            let words = candidate.word.split(separator: " ").map { lexicon.displayForm(of: String($0)) ?? String($0) }
            return WordDecoder.Candidate(word: words.joined(separator: " "), score: candidate.score)
        }
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
