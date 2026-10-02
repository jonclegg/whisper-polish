import Foundation
import Observation
import UIKit

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
    var isPickingStyle = false

    @ObservationIgnored unowned let controller: KeyboardViewController
    @ObservationIgnored let predictor = Predictor()
    @ObservationIgnored private var polishTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var deleteRepeatTask: Task<Void, Never>?
    @ObservationIgnored private var undo: (original: String, polished: String)?
    @ObservationIgnored private var lastShiftTap = Date.distantPast
    @ObservationIgnored private var isShiftHeld = false
    @ObservationIgnored private var typedWhileShiftHeld = false
    @ObservationIgnored private var layoutBeforeSwitch: KeyboardLayout = .letters
    @ObservationIgnored private var pendingCorrection: String?
    @ObservationIgnored private var lastAutocorrection: Predictor.Autocorrection?
    @ObservationIgnored private var revertCandidate: Predictor.Autocorrection?
    @ObservationIgnored private var insertedSuggestionSpace = false
    /// Where each recently typed letter was touched, in key units, so corrections
    /// can tell a near miss on a neighboring key from a deliberate letter.
    @ObservationIgnored private var letterTouches: [(letter: Character, point: CGPoint?)] = []

    init(controller: KeyboardViewController) {
        self.controller = controller
        Task {
            predictor.setLexicon(await Task.detached { Lexicon.load() }.value)
            updateSuggestions()
        }
    }

    private var proxy: UITextDocumentProxy { controller.textDocumentProxy }
    private var textBeforeCursor: String { hostText.textBefore(reported: proxy.documentContextBeforeInput) }

    // MARK: - Editing

    @ObservationIgnored private var hostText = HostTextTracker()
    @ObservationIgnored private var lastSyncedState = ""
    @ObservationIgnored private var suggestionsScheduled = false

    private func insert(_ text: String) {
        hostText.willInsert(text, reported: proxy.documentContextBeforeInput, document: proxy.documentIdentifier)
        proxy.insertText(text)
    }

    private func delete(count: Int) {
        guard count > 0 else { return }
        hostText.willDelete(count, reported: proxy.documentContextBeforeInput, document: proxy.documentIdentifier)
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
        ].joined(separator: "\u{1}")
    }

    func refresh() {
        hasFullAccess = controller.hasFullAccess
        needsInputModeSwitchKey = controller.needsInputModeSwitchKey
        layout = proxy.keyboardType == .numbersAndPunctuation ? .numbers : .letters
        isPickingStyle = false
        letterTouches = []
        forgetLocalEdits()
        resetTypingState()
        syncWithDocument()
        guard hasFullAccess else { return }
        let customJSON = AppGroup.defaults.string(forKey: SettingsKeys.customStyles) ?? ""
        styles = PolishStyle.all(customJSON: customJSON)
        let defaultID = AppGroup.defaults.string(forKey: SettingsKeys.defaultStyle) ?? PolishStyle.email.id
        selectedStyle = PolishStyle.find(id: defaultID, customJSON: customJSON) ?? .email
    }

    /// The host reports each keystroke several times, mostly echoes of edits already synced.
    func textDidChange() {
        hostText.reconcile(reported: proxy.documentContextBeforeInput, document: proxy.documentIdentifier)
        guard hostText.local == nil, documentState != lastSyncedState else { return }
        syncWithDocument()
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
        guard layout == .letters, nearest.count == 1, let letter = nearest.first,
              (proxy.selectedText ?? "").isEmpty else { return nearest }
        let odds = predictor.letterOdds(for: TypingContext(before: textBeforeCursor))
        return String(KeyResolver.resolve(point, nearest: letter, odds: odds))
    }

    func keyUp(_ key: Key, at point: CGPoint? = nil) {
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

    func apply(_ suggestion: Suggestion) {
        let before = textBeforeCursor
        let typed = TypingContext(before: before).partialWord
        if suggestion.learns { predictor.learn(suggestion.text) }
        if typed.isEmpty, let last = before.last, !last.isWhitespace {
            insert(" ")
        }
        replace(typed, with: suggestion.text)
        insert(" ")
        layout = .letters
        didType()
        insertedSuggestionSpace = true
    }

    func moveCursor(by offset: Int) {
        forgetLocalEdits()
        proxy.adjustTextPosition(byCharacterOffset: offset)
    }

    func cursorMoveEnded() {
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
            insert(" ")
        }
        layout = .letters
        didType()
        lastAutocorrection = correction
    }

    private func typeReturn() {
        guard returnKey.isEnabled else { return }
        applyPendingCorrection()
        insert("\n")
        didType()
    }

    @discardableResult
    private func applyPendingCorrection() -> Predictor.Autocorrection? {
        if suggestionsScheduled { updateSuggestions() }
        guard let correction = pendingCorrection else { return nil }
        let typed = TypingContext(before: textBeforeCursor).partialWord
        replace(typed, with: correction)
        return (typed, correction)
    }

    private func replace(_ typed: String, with text: String) {
        guard typed != text else { return }
        delete(count: typed.count)
        insert(text)
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
        } else {
            delete(count: spaces + word)
        }
        letterTouches = []
        didType()
    }

    // MARK: - Typing state

    private func didType() {
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

    private func syncWithDocument() {
        lastSyncedState = documentState
        updateAutoCapitalization()
        updateTraits()
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

    private func updateSuggestions() {
        suggestionsScheduled = false
        guard (proxy.selectedText ?? "").isEmpty else {
            if !suggestions.isEmpty { suggestions = [] }
            pendingCorrection = nil
            return
        }
        let context = TypingContext(before: textBeforeCursor)
        let result = predictor.suggestions(
            for: context,
            touches: touches(for: context.partialWord),
            allowsCorrection: proxy.autocorrectionType != .no,
            revert: revertCandidate
        )
        if suggestions != result.suggestions { suggestions = result.suggestions }
        pendingCorrection = result.correction
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

    private func updateTraits() {
        let newBottomRow: BottomRowStyle = switch proxy.keyboardType ?? .default {
        case .emailAddress: .email
        case .URL: .url
        case .webSearch: .webSearch
        case .twitter: .twitter
        default: .standard
        }
        if bottomRow != newBottomRow { bottomRow = newBottomRow }

        let type = proxy.returnKeyType ?? .default
        let isEmpty = textBeforeCursor.isEmpty && (proxy.documentContextAfterInput ?? "").isEmpty
        let newReturnKey = ReturnKey(
            label: Self.returnLabel(type),
            isPrimary: type != .default && type != .next,
            isEnabled: !(proxy.enablesReturnKeyAutomatically ?? false) || !isEmpty
        )
        if returnKey != newReturnKey { returnKey = newReturnKey }
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
        show(.polishing)
        polishTask = Task {
            let selected = proxy.selectedText ?? ""
            let text = if selected.isEmpty { await DocumentReader(proxy: proxy).readWholeDocument() } else { selected }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                show(.message("Type or select some text to polish."))
                return
            }
            do {
                let result = try await Polisher.polish(text: text, style: style, transactionJWS: jws).result
                try Task.checkCancellation()
                // Without a selection the reader left the cursor at the end of the field.
                if selected.isEmpty {
                    for _ in 0..<text.count { proxy.deleteBackward() }
                }
                proxy.insertText(result.text)
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
