import Foundation
import Observation
import UIKit
import os

@MainActor
@Observable
final class KeyboardModel {
    enum Shift {
        case off
        case once
        case locked
    }

    enum Notice: Equatable {
        case polishing
        case polished
        case dictated
        case saveToProfile(ProfileField, String)
        case savedToProfile
        case message(String)
    }

    struct ReturnKey: Equatable {
        var label = "return"
        var isPrimary = false
        var isEnabled = true
    }

    private static let fullAccessMessage = "Turn on Allow Full Access in Settings › General › Keyboard › Keyboards › Whisper Polish to polish and dictate."
    /// Punctuation that pulls back the space a tapped suggestion inserted.
    private static let attachingPunctuation: Set<String> = [".", ",", "?", "!", ":", ";"]

    private(set) var styles: [PolishStyle] = PolishStyle.builtIns
    private(set) var selectedStyle: PolishStyle = .email
    private(set) var hasFullAccess = false
    private(set) var needsInputModeSwitchKey = false
    private(set) var layout: KeyboardLayout = .letters
    private(set) var bottomRow: BottomRowStyle = .standard
    private(set) var returnKey = ReturnKey()
    private(set) var shift: Shift = .off
    private(set) var suggestions: [Suggestion] = []
    private(set) var notice: Notice?
    private(set) var offeredPasteboardChangeCount: Int?
    /// Profile values the focused form field could take.
    private(set) var autofillCandidates: [AutofillProfile.Value] = []
    private(set) var options = KeyboardOptions()
    var isPickingStyle = false

    @ObservationIgnored unowned let controller: KeyboardViewController
    @ObservationIgnored let prediction = PredictionEngine()
    /// Set once earlier sessions' learning has loaded into the predictor.
    @ObservationIgnored private var isPredictorLoaded = false
    /// Each bar update asks the predictor anew; only the latest answer is shown.
    @ObservationIgnored private var requestNumber = 0
    /// The autocorrection the latest answer had for the word being typed.
    @ObservationIgnored private var latestCorrection: (request: Int, correction: String?)?
    /// How likely each letter is to come next after `text`, so a touch down only looks it up.
    @ObservationIgnored private var letterOdds: (text: String, odds: [Character: Double])?
    /// What the keyboard has learned from your typing; it stays in the keyboard's own container.
    private static let personalURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("personal-typing.bin")
    /// Where keyboards before the compact file kept it.
    private static let legacyPersonalURL = personalURL.deletingPathExtension().appendingPathExtension("json")
    @ObservationIgnored private var polishTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var deleteRepeatTask: Task<Void, Never>?
    @ObservationIgnored private var undo: (original: String, polished: String)?
    @ObservationIgnored private var lastShiftTap = Date.distantPast
    @ObservationIgnored private var isShiftHeld = false
    @ObservationIgnored private var typedWhileShiftHeld = false
    @ObservationIgnored private var layoutBeforeSwitch: KeyboardLayout = .letters
    @ObservationIgnored private var lastAutocorrection: Predictor.Autocorrection?
    @ObservationIgnored private var revertCandidate: Predictor.Autocorrection?
    @ObservationIgnored private var insertedSuggestionSpace = false
    @ObservationIgnored private var floatingCursor: FloatingCursor?
    /// Where each recently typed letter was touched, in key units, so corrections
    /// can tell a near miss on a neighboring key from a deliberate letter.
    @ObservationIgnored private var letterTouches: [(letter: Character, point: CGPoint?)] = []
    @ObservationIgnored private var dismissedPasteboardChangeCount: Int
    @ObservationIgnored private var profile = AutofillProfile.empty
    @ObservationIgnored private var autofill = AutofillSession()

    private static let dismissedPasteboardChangeCountKey = "dismissedPasteboardChangeCount"
    /// Intervals for Instruments' Points of Interest: what each keystroke and keyboard open costs.
    static let signposter = OSSignposter(subsystem: "com.jonclegg.WhisperPolish.Keyboard", category: .pointsOfInterest)

    /// The word list and model load once per keyboard process. iOS makes a new
    /// keyboard each time one is shown, and loading them again each time cost
    /// memory and kept the bar empty while they loaded.
    private static let sharedModels = Task.detached {
        Predictor.warmUpSpellChecker()
        let lexicon = Lexicon.load()
        let wordModel = try! WordModel(contentsOf: Bundle.main.url(forResource: "word-model", withExtension: "bin")!)
        return (lexicon, wordModel, WordDecoder(lexicon: lexicon, oddsIds: wordModel.ids))
    }
    /// A space waits this long at most for the correction of a word the bar hasn't caught up with.
    private static let correctionDeadline = DispatchTimeInterval.milliseconds(40)

    init(controller: KeyboardViewController) {
        self.controller = controller
        dismissedPasteboardChangeCount = UserDefaults.standard.integer(forKey: Self.dismissedPasteboardChangeCountKey)
        let opening = Self.signposter.beginInterval("Open", id: Self.signposter.makeSignpostID())
        Task {
            let (lexicon, wordModel, decoder) = await Self.sharedModels.value
            prediction.perform { [personalURL = Self.personalURL, legacyPersonalURL = Self.legacyPersonalURL] predictor in
                // What was learned is saved each time the keyboard closes; a new process reads it back.
                let personal = PredictionEngine.savedPersonal ?? PersonalModel.load(from: personalURL, migratingFrom: legacyPersonalURL)
                Self.signposter.withIntervalSignpost("setLexicon") {
                    predictor.setLexicon(lexicon, wordModel: wordModel, decoder: decoder, personal: personal)
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    isPredictorLoaded = true
                    syncLearnedWords()
                    updateSuggestions()
                    Self.signposter.endInterval("Open", opening)
                }
            }
        }
    }

    private var proxy: UITextDocumentProxy { controller.textDocumentProxy }
    /// Safari reports no document while focus moves between form fields, which
    /// `proxy.documentIdentifier`'s non-optional import traps on.
    private var documentIdentifier: UUID? {
        (proxy as? NSObject)?.value(forKey: "documentIdentifier") as? UUID
    }
    private var textBeforeCursor: String { hostText.textBefore(reported: proxy.documentContextBeforeInput) }

    // MARK: - Editing

    @ObservationIgnored private var hostText = HostTextTracker()
    @ObservationIgnored private var contextMemory = ContextMemory()
    @ObservationIgnored private var lastSyncedState = ""
    @ObservationIgnored private var suggestionsScheduled = false
    @ObservationIgnored private var keptWords = KeptWords()
    /// The field the held words were typed in.
    @ObservationIgnored private var keptWordsDocument: UUID?

    private func insert(_ text: String) {
        hostText.willInsert(text, reported: proxy.documentContextBeforeInput, after: proxy.documentContextAfterInput, document: documentIdentifier)
        keptWords.typed(text.count)
        proxy.insertText(text)
    }

    private func delete(count: Int) {
        guard count > 0 else { return }
        hostText.willDelete(count, reported: proxy.documentContextBeforeInput, after: proxy.documentContextAfterInput, document: documentIdentifier)
        keptWords.deleted(count)
        for _ in 0..<count { proxy.deleteBackward() }
    }

    private func forgetLocalEdits() {
        hostText.forget()
    }

    private var documentState: String {
        [
            textBeforeCursor,
            proxy.documentContextAfterInput ?? "",
            proxy.selectedText ?? "",
            "\(proxy.keyboardType?.rawValue ?? -1) \(proxy.returnKeyType?.rawValue ?? -1) \(proxy.autocapitalizationType?.rawValue ?? -1)",
            proxy.textContentType?.rawValue ?? "",
            documentIdentifier?.uuidString ?? "",
        ].joined(separator: "\u{1}")
    }

    func refresh() {
        learnKeptWords()
        hasFullAccess = controller.hasFullAccess
        options = KeyboardOptions.load()
        needsInputModeSwitchKey = controller.needsInputModeSwitchKey
        layout = proxy.keyboardType == .numbersAndPunctuation ? .numbers : .letters
        isPickingStyle = false
        letterTouches = []
        forgetLocalEdits()
        resetTypingState()
        profile = hasFullAccess ? AutofillProfile.load() : .empty
        syncWithDocument()
        updatePasteOffer()
        guard hasFullAccess else { return }
        syncLearnedWords()
        let customJSON = AppGroup.defaults.string(forKey: SettingsKeys.customStyles) ?? ""
        styles = PolishStyle.all(customJSON: customJSON)
        let defaultID = AppGroup.defaults.string(forKey: SettingsKeys.defaultStyle) ?? PolishStyle.email.id
        selectedStyle = PolishStyle.find(id: defaultID, customJSON: customJSON) ?? .email
    }

    /// The host reports each keystroke several times, mostly echoes of edits already synced.
    func textDidChange() {
        hostText.reconcile(
            reported: proxy.documentContextBeforeInput,
            after: proxy.documentContextAfterInput,
            document: documentIdentifier
        )
        guard hostText.local == nil, documentState != lastSyncedState else {
            Self.signposter.emitEvent("Host echo")
            return
        }
        Self.signposter.withIntervalSignpost("Resync") { syncWithDocument() }
    }

    // MARK: - Keys

    func keyDown(_ key: Key) {
        switch key {
        case .delete:
            startDeleting()
        case .shift:
            tapShift()
            isShiftHeld = true
            typedWhileShiftHeld = false
        case .layout(let newLayout):
            layoutBeforeSwitch = layout
            layout = newLayout
        case .character, .space, .returnKey, .nextKeyboard:
            break
        }
    }

    /// The letter a touch at `point` (in key units) most likely meant, which near
    /// a key's edge can be the neighbor that fits the word being typed.
    func resolveLetter(at point: CGPoint, nearest: String) -> String {
        guard options.predictions, layout == .letters, nearest.count == 1, let letter = nearest.first,
              (proxy.selectedText ?? "").isEmpty else { return nearest }
        // Worked out with the bar after the last key; until it's in, the touched key types.
        guard let letterOdds, letterOdds.text == predictionText else { return nearest }
        return Self.signposter.withIntervalSignpost("Touch down") {
            String(KeyResolver.resolve(point, nearest: letter, odds: letterOdds.odds))
        }
    }

    func keyUp(_ key: Key, at point: CGPoint? = nil) {
        let state = Self.signposter.beginInterval("Key up", id: Self.signposter.makeSignpostID())
        defer { Self.signposter.endInterval("Key up", state) }
        switch key {
        case .character(let character):
            type(character, at: point)
        case .space:
            typeSpace()
        case .returnKey:
            typeReturn()
        case .delete:
            stopDeleting()
        case .shift:
            releaseShift()
        case .layout, .nextKeyboard:
            break
        }
    }

    func keyCancelled(_ key: Key) {
        switch key {
        case .delete: stopDeleting()
        case .shift: releaseShift()
        default: break
        }
    }

    /// Sliding off 123 onto a symbol types it and goes back, like the system keyboard.
    func typeAfterLayoutSlide(_ character: String) {
        type(character)
        layout = layoutBeforeSwitch
    }

    /// A tap on the bar's `index`th slot, from `SuggestionTapView`.
    func tapBarSlot(_ index: Int) {
        if !autofillCandidates.isEmpty {
            if index < autofillCandidates.count { fill(autofillCandidates[index]) }
        } else if index < suggestions.count {
            apply(suggestions[index])
        }
    }

    /// How many slots `SuggestionTapView` splits the bar into; none while the bar shows something else.
    var barSlotCount: Int {
        guard options.barTapLayer, !isPickingStyle, notice == nil else { return 0 }
        if !autofillCandidates.isEmpty { return autofillCandidates.count }
        return offeredPasteboardChangeCount == nil ? 3 : 0
    }

    func apply(_ suggestion: Suggestion) {
        if options.suggestionClick { UIDevice.current.playInputClick() }
        let before = textBeforeCursor
        let typed = TypingContext(before: before).partialWord
        if suggestion.learns { prediction.perform { $0.learn(suggestion.text) } }
        let separator = typed.isEmpty && before.last.map { !$0.isWhitespace } == true ? " " : ""
        // The word and the space after it reach the host as one edit.
        replace(typed, with: separator + suggestion.text + " ")
        learnFinishedWord(before: String(before.dropLast(typed.count)) + separator + suggestion.text, after: 1)
        layout = .letters
        didType()
        insertedSuggestionSpace = true
    }

    /// `show` draws the panel the cursor moves through, whenever its text or the cursor changes.
    func cursorMoveBegan(width: CGFloat, show: @escaping (TrackpadLayout, Int) -> Void) {
        forgetLocalEdits()
        floatingCursor = FloatingCursor(proxy: proxy, width: width, onChange: show)
    }

    func moveCursor(by delta: CGVector) {
        floatingCursor!.move(by: delta)
    }

    func cursorMoveEnded() {
        learnKeptWords()
        floatingCursor!.end()
        floatingCursor = nil
        letterTouches = []
        forgetLocalEdits()
        resetTypingState()
        syncWithDocument()
    }

    private func type(_ character: String, at point: CGPoint? = nil) {
        if character.count == 1, let letter = character.lowercased().first, letter.isLetter {
            letterTouches.append((letter, point))
            if letterTouches.count > 48 { letterTouches.removeFirst(letterTouches.count - 48) }
        } else {
            letterTouches = []
        }
        let text = shift == .off ? character : character.uppercased()
        if Self.attachingPunctuation.contains(character) {
            if insertedSuggestionSpace, textBeforeCursor.hasSuffix(" ") {
                delete(count: 1)
                insert(text + " ")
                didType()
                return
            }
            applyPendingCorrection()
            learnFinishedWord()
        }
        insert(text)
        if character == "'" { layout = .letters }
        didType()
    }

    /// Two spaces after a word become ". ", like the system keyboard.
    private func typeSpace() {
        let before = textBeforeCursor
        var correction: Predictor.Autocorrection?
        if before.hasSuffix(" "), let previous = before.dropLast().last, previous.isLetter || previous.isNumber {
            delete(count: 1)
            insert(". ")
        } else {
            correction = applyPendingCorrection()
            learnFinishedWord()
            insert(" ")
        }
        layout = .letters
        didType()
        lastAutocorrection = correction
    }

    private func typeReturn() {
        guard returnKey.isEnabled else { return }
        applyPendingCorrection()
        learnFinishedWord()
        insert("\n")
        learnKeptWords()
        didType()
    }

    @discardableResult
    private func applyPendingCorrection() -> Predictor.Autocorrection? {
        let correction: String?
        if !suggestionsScheduled, let latestCorrection, latestCorrection.request == requestNumber {
            correction = latestCorrection.correction
        } else {
            correction = waitForCorrection()
        }
        guard let correction else { return nil }
        let typed = TypingContext(before: textBeforeCursor).partialWord
        replace(typed, with: correction)
        return (typed, correction)
    }

    /// The bar hasn't caught up with the last key, so the word's correction is worked
    /// out now, waiting a moment at most; a word it can't check in time stays as typed.
    private func waitForCorrection() -> String? {
        guard let request = predictionRequest() else { return nil }
        return Self.signposter.withIntervalSignpost("Correction wait") {
            prediction.performAndWait(until: .now() + Self.correctionDeadline) { predictor in
                predictor.suggestions(for: request.context, touches: request.touches, allowsCorrection: request.allowsCorrection, revert: request.revert).correction
            } ?? nil
        }
    }

    func savePersonal() {
        // Before earlier sessions' learning loads there's only an empty model, which would overwrite it.
        guard isPredictorLoaded else { return }
        learnKeptWords()
        let publishes = hasFullAccess
        prediction.perform { [personalURL = Self.personalURL] predictor in
            let personal = predictor.personalModel
            PredictionEngine.savedPersonal = personal
            Task.detached(priority: .utility) { personal.save(to: personalURL) }
            if publishes { LearnedWords.publish(predictor.learnedWords) }
        }
    }

    /// Forgets the learned words removed in the app, then lists what's left there.
    private func syncLearnedWords() {
        guard hasFullAccess, isPredictorLoaded else { return }
        let removals = LearnedWords.takeRemovals()
        guard !removals.isEmpty else {
            prediction.perform { LearnedWords.publish($0.learnedWords) }
            return
        }
        prediction.perform { $0.forget(removals) }
        savePersonal()
        updateSuggestions()
    }

    /// The word just before the cursor is done; the predictor learns it in its sentence
    /// once it's clear the user kept it. `before` is the text up to the end of the word
    /// when it's different from the host's, and `after` how far past it the cursor is.
    private func learnFinishedWord(before: String? = nil, after: Int = 0) {
        let context = TypingContext(before: before ?? textBeforeCursor)
        guard !context.partialWord.isEmpty, WritingField.holdsWriting(proxy) else { return }
        let document = documentIdentifier
        if document != keptWordsDocument { learnKeptWords() }
        keptWordsDocument = document
        learn(keptWords.finished(context.partialWord, previous: context.previousWords, after: after))
    }

    /// The user moved on, so the words still held were kept.
    private func learnKeptWords() {
        learn(keptWords.flush())
    }

    private func learn(_ words: [KeptWords.Word]) {
        guard !words.isEmpty else { return }
        prediction.perform { predictor in
            for word in words { predictor.learnTyped(word.text, after: word.previous) }
        }
    }

    /// Keeps what already matches: every deleted character and insert is a round
    /// trip the host lays out, which shows as lag on a long word.
    private func replace(_ typed: String, with text: String) {
        let kept = zip(typed, text).prefix { $0 == $1 }.count
        delete(count: typed.count - kept)
        if kept < text.count { insert(String(text.dropFirst(kept))) }
    }

    // MARK: - Delete

    /// Holding delete repeats by character, then speeds up to whole words.
    private func startDeleting() {
        deleteBackward()
        deleteRepeatTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            var repeats = 0
            while !Task.isCancelled {
                UIDevice.current.playInputClick()
                if repeats < 12 {
                    deleteBackward()
                    try? await Task.sleep(for: .milliseconds(90))
                } else {
                    deleteWordBackward()
                    try? await Task.sleep(for: .milliseconds(220))
                }
                repeats += 1
            }
        }
    }

    private func stopDeleting() {
        deleteRepeatTask?.cancel()
        deleteRepeatTask = nil
    }

    private func deleteBackward() {
        let autocorrection = lastAutocorrection
        if !letterTouches.isEmpty { letterTouches.removeLast() }
        if textBeforeCursor.isEmpty {
            // Nothing known before the cursor, so let the host decide what goes.
            proxy.deleteBackward()
            forgetLocalEdits()
            keptWords.drop()
        } else {
            delete(count: 1)
        }
        didType()
        // Backing into an autocorrected word offers the original back.
        guard let autocorrection, TypingContext(before: textBeforeCursor).partialWord == autocorrection.replacement else { return }
        revertCandidate = autocorrection
    }

    private func deleteWordBackward() {
        let before = textBeforeCursor
        let spaces = before.reversed().prefix { $0.isWhitespace }.count
        let word = before.dropLast(spaces).reversed().prefix { !$0.isWhitespace }.count
        if before.isEmpty {
            proxy.deleteBackward()
            forgetLocalEdits()
            keptWords.drop()
        } else {
            delete(count: spaces + word)
        }
        letterTouches = []
        didType()
    }

    // MARK: - Typing state

    private func didType() {
        dismissPasteOffer()
        polishTask?.cancel()
        undo = nil
        if notice != nil {
            noticeTask?.cancel()
            notice = nil
        }
        resetTypingState()
        if isShiftHeld {
            typedWhileShiftHeld = true
        } else if shift == .once {
            shift = .off
        }
        syncWithDocument()
    }

    private func resetTypingState() {
        insertedSuggestionSpace = false
        lastAutocorrection = nil
        revertCandidate = nil
    }

    /// What predictions read: the text before the cursor, back past the sentence the host reports.
    private var predictionText: String {
        options.wholeMessage ? contextMemory.text : textBeforeCursor
    }

    private struct PredictionRequest: Sendable {
        let text: String
        let context: TypingContext
        let touches: [CGPoint?]
        let allowsCorrection: Bool
        let revert: Predictor.Autocorrection?
    }

    /// What to ask the predictor about the text as it is now, or nil when the bar shows no predictions.
    private func predictionRequest() -> PredictionRequest? {
        guard options.predictions, isPredictorLoaded, (proxy.selectedText ?? "").isEmpty else { return nil }
        let text = predictionText
        let context = TypingContext(before: text)
        return PredictionRequest(
            text: text,
            context: context,
            touches: touches(for: context.partialWord),
            allowsCorrection: options.autocorrect && proxy.autocorrectionType != .no,
            revert: revertCandidate
        )
    }

    private func syncWithDocument() {
        lastSyncedState = documentState
        // Each read asks the host app, so the text after the cursor and the document are read once here.
        let after = proxy.documentContextAfterInput ?? ""
        let document = documentIdentifier
        // An emptied field is a sent message, and deletes in the next shouldn't reach back into it.
        if after.isEmpty, textBeforeCursor.isEmpty { learnKeptWords() }
        if options.wholeMessage { _ = contextMemory.extend(textBeforeCursor, after: after, document: document) }
        updateAutoCapitalization()
        updateTraits(after: after)
        updateAutofill(after: after, document: document)
        scheduleSuggestions()
    }

    /// Suggestions wait until the keystroke has been handled, so a slow
    /// lookup never holds up the next key. Corrections refresh them first.
    private func scheduleSuggestions() {
        guard !suggestionsScheduled else { return }
        suggestionsScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, suggestionsScheduled else { return }
            updateSuggestions()
        }
    }

    /// Asks the predictor on its own queue; the answer shows unless a newer question went after it.
    private func updateSuggestions() {
        suggestionsScheduled = false
        requestNumber += 1
        let number = requestNumber
        guard let request = predictionRequest() else {
            if !suggestions.isEmpty { suggestions = [] }
            latestCorrection = (number, nil)
            letterOdds = nil
            return
        }
        prediction.perform { predictor in
            let state = Self.signposter.beginInterval("Suggestions", id: Self.signposter.makeSignpostID())
            let result = predictor.suggestions(for: request.context, touches: request.touches, allowsCorrection: request.allowsCorrection, revert: request.revert)
            let steps = predictor.lastModelSteps
            let odds = predictor.letterOdds(for: request.context)
            Self.signposter.endInterval("Suggestions", state, "model steps \(steps)")
            DispatchQueue.main.async { [weak self] in
                self?.receive(result, letterOdds: odds, after: request.text, for: number)
            }
        }
    }

    private func receive(_ result: Predictor.Result, letterOdds odds: [Character: Double], after text: String, for number: Int) {
        guard number == requestNumber else { return }
        letterOdds = (text, odds)
        if suggestions != result.suggestions { suggestions = result.suggestions }
        latestCorrection = (number, result.correction)
    }

    /// Touch points for `word`, or nil for letters that weren't typed on these keys just now.
    private func touches(for word: String) -> [CGPoint?] {
        let letters = Array(word.lowercased())
        let recent = letterTouches.suffix(letters.count)
        guard recent.count == letters.count, recent.map({ $0.letter }) == letters else {
            return Array(repeating: nil, count: letters.count)
        }
        return recent.map { $0.point }
    }

    private func updateTraits(after: String) {
        let newBottomRow: BottomRowStyle = switch proxy.keyboardType ?? .default {
        case .emailAddress: .email
        case .URL: .url
        case .webSearch: .webSearch
        case .twitter: .twitter
        default: .standard
        }
        if bottomRow != newBottomRow { bottomRow = newBottomRow }

        let type = proxy.returnKeyType ?? .default
        let isEmpty = textBeforeCursor.isEmpty && after.isEmpty
        let newReturnKey = ReturnKey(
            label: Self.returnLabel(type),
            isPrimary: type != .default && type != .next,
            isEnabled: !(proxy.enablesReturnKeyAutomatically ?? false) || !isEmpty
        )
        if returnKey != newReturnKey { returnKey = newReturnKey }
    }

    // MARK: - AutoFill

    private func updateAutofill(after: String, document: UUID?) {
        guard options.autofill else {
            if !autofillCandidates.isEmpty { autofillCandidates = [] }
            return
        }
        let field = hasFullAccess ? ProfileField(contentType: proxy.textContentType, keyboardType: proxy.keyboardType) : nil
        let before = textBeforeCursor
        if let offer = autofill.observe(field: field, document: document, text: before + after, profile: profile),
           AutofillProfile.offersToSaveTyping() {
            show(.saveToProfile(offer.field, offer.text))
        }
        let candidates = autofill.candidates(before: before, after: after, profile: profile)
        if autofillCandidates != candidates { autofillCandidates = candidates }
    }

    /// Replaces what's typed in the field with `value`.
    func fill(_ value: AutofillProfile.Value) {
        replace(textBeforeCursor, with: value.text)
        autofill.didFill(value)
        profile = AutofillProfile.load()
        profile.markUsed(value.id)
        profile.save()
        didType()
    }

    func saveOfferedValue() {
        guard case .saveToProfile(let field, let text) = notice else { return }
        // The app may have changed the profile since the keyboard opened.
        profile = AutofillProfile.load()
        profile.add(text, for: field, source: .typed)
        profile.save()
        show(.savedToProfile)
        updateAutofill(after: proxy.documentContextAfterInput ?? "", document: documentIdentifier)
    }

    private static func returnLabel(_ type: UIReturnKeyType) -> String {
        switch type {
        case .go: "go"
        case .google, .yahoo, .search: "search"
        case .join: "join"
        case .next: "next"
        case .route: "route"
        case .send: "send"
        case .done: "done"
        case .emergencyCall: "Emergency"
        case .continue: "continue"
        default: "return"
        }
    }

    // MARK: - Shift

    private func tapShift() {
        let now = Date()
        if shift == .once, now.timeIntervalSince(lastShiftTap) < 0.35 {
            shift = .locked
        } else {
            shift = shift == .off ? .once : .off
        }
        lastShiftTap = now
    }

    /// Holding shift while typing capitalizes only those letters.
    private func releaseShift() {
        guard isShiftHeld else { return }
        isShiftHeld = false
        guard typedWhileShiftHeld, shift == .once else { return }
        shift = .off
        updateAutoCapitalization()
    }

    private func updateAutoCapitalization() {
        guard shift != .locked, !isShiftHeld else { return }
        let before = textBeforeCursor
        let capitalizes = switch proxy.autocapitalizationType ?? .sentences {
        case UITextAutocapitalizationType.none: false
        case .allCharacters: true
        case .words: before.last?.isWhitespace ?? true
        default: Self.startsSentence(before)
        }
        let newShift: Shift = capitalizes ? .once : .off
        if shift != newShift { shift = newShift }
    }

    private static func startsSentence(_ before: String) -> Bool {
        let trimmed = before.replacingOccurrences(of: " ", with: "")
        return trimmed.isEmpty
            || before.hasSuffix("\n")
            || (before.hasSuffix(" ") && ".!?".contains(trimmed.last!))
    }

    // MARK: - Polish

    func selectStyle(_ style: PolishStyle) {
        selectedStyle = style
        AppGroup.defaults.set(style.id, forKey: SettingsKeys.defaultStyle)
        isPickingStyle = false
    }

    func togglePicker() {
        guard hasFullAccess else { return show(.message(Self.fullAccessMessage)) }
        isPickingStyle.toggle()
    }

    func polish() {
        guard hasFullAccess else { return show(.message(Self.fullAccessMessage)) }
        guard notice != .polishing else { return }
        isPickingStyle = false
        let jws = AppGroup.defaults.string(forKey: SettingsKeys.cloudEntitlementJWS)
        let style = selectedStyle
        AppGroup.defaults.set(style.id, forKey: SettingsKeys.defaultStyle)
        forgetLocalEdits()
        learnKeptWords()
        show(.polishing)
        polishTask = Task {
            do {
                let selected = proxy.selectedText ?? ""
                let reader = DocumentReader(proxy: proxy)
                let text = selected.isEmpty ? try await reader.readWholeDocument() : selected
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    show(.message("Type or select some text to polish."))
                    return
                }
                let result = try await Polisher.polish(text: text, style: style, transactionJWS: jws).result
                try Task.checkCancellation()
                // Without a selection the reader left the cursor at the end of the field.
                if selected.isEmpty {
                    try reader.replace(text, with: result.text)
                } else {
                    proxy.insertText(result.text)
                }
                forgetLocalEdits()
                undo = (text, result.text)
                show(.polished)
                syncWithDocument()
            } catch is CancellationError {
                notice = nil
            } catch let error as URLError where error.code == .cancelled {
                notice = nil
            } catch {
                show(.message(error.localizedDescription))
            }
        }
    }

    func undoPolish() {
        guard let undo else { return }
        for _ in 0..<undo.polished.count { proxy.deleteBackward() }
        proxy.insertText(undo.original)
        forgetLocalEdits()
        self.undo = nil
        notice = nil
        syncWithDocument()
    }

    // MARK: - App handoff

    func record() {
        guard hasFullAccess else { return show(.message(Self.fullAccessMessage)) }
        controller.openContainingApp(AppGroup.dictationURL)
    }

    func createStyle() {
        guard hasFullAccess else { return }
        isPickingStyle = false
        controller.openContainingApp(AppGroup.newStyleURL)
    }

    func insertPendingDictation() {
        guard hasFullAccess,
              let text = AppGroup.defaults.string(forKey: SettingsKeys.pendingDictation) else { return }
        AppGroup.defaults.removeObject(forKey: SettingsKeys.pendingDictation)
        insert(text)
        syncWithDocument()
        show(.dictated)
    }

    // MARK: - Clipboard

    /// The system keyboard offers the current pasteboard once, until the user pastes it or types.
    /// Only the pasteboard's metadata is checked here, which doesn't raise iOS's paste prompt;
    /// the text itself arrives through the bar's paste control.
    func updatePasteOffer() {
        let pasteboard = UIPasteboard.general
        guard hasFullAccess, pasteboard.hasStrings, pasteboard.changeCount != dismissedPasteboardChangeCount else {
            offeredPasteboardChangeCount = nil
            return
        }
        offeredPasteboardChangeCount = pasteboard.changeCount
    }

    func paste(_ text: String) {
        insert(text)
        dismissPasteOffer()
        syncWithDocument()
    }

    private func dismissPasteOffer() {
        guard let changeCount = offeredPasteboardChangeCount else { return }
        dismissedPasteboardChangeCount = changeCount
        UserDefaults.standard.set(changeCount, forKey: Self.dismissedPasteboardChangeCountKey)
        offeredPasteboardChangeCount = nil
    }

    // MARK: - Notices

    private func show(_ newNotice: Notice) {
        noticeTask?.cancel()
        notice = newNotice
        guard newNotice != .polishing else { return }
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            notice = nil
            undo = nil
        }
    }
}
