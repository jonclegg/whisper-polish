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

    private(set) var styles: [PolishStyle] = PolishStyle.builtIns
    private(set) var selectedStyle: PolishStyle = .email
    private(set) var hasFullAccess = false
    private(set) var needsInputModeSwitchKey = false
    private(set) var layout: KeyboardLayout = .letters
    private(set) var shift: Shift = .off
    private(set) var notice: Notice?
    var isPickingStyle = false

    @ObservationIgnored unowned let controller: KeyboardViewController
    @ObservationIgnored private var polishTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var deleteRepeatTask: Task<Void, Never>?
    @ObservationIgnored private var undo: (original: String, polished: String)?
    @ObservationIgnored private var lastShiftTap = Date.distantPast
    @ObservationIgnored private let haptics = UIImpactFeedbackGenerator(style: .light)

    init(controller: KeyboardViewController) {
        self.controller = controller
    }

    private var proxy: UITextDocumentProxy { controller.textDocumentProxy }

    func refresh() {
        hasFullAccess = controller.hasFullAccess
        needsInputModeSwitchKey = controller.needsInputModeSwitchKey
        layout = .letters
        isPickingStyle = false
        updateAutoCapitalization()
        guard hasFullAccess else { return }
        let customJSON = AppGroup.defaults.string(forKey: SettingsKeys.customStyles) ?? ""
        styles = PolishStyle.all(customJSON: customJSON)
        let defaultID = AppGroup.defaults.string(forKey: SettingsKeys.defaultStyle) ?? PolishStyle.email.id
        selectedStyle = PolishStyle.find(id: defaultID, customJSON: customJSON) ?? .email
    }

    // MARK: - Keys

    func keyDown(_ key: Key) {
        if hasFullAccess { haptics.impactOccurred() }
        guard key == .delete else { return }
        deleteBackward()
        deleteRepeatTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            while !Task.isCancelled {
                deleteBackward()
                try? await Task.sleep(for: .milliseconds(90))
            }
        }
    }

    /// Called when a touch ends or is cancelled, so delete never repeats forever.
    func keyReleased() {
        deleteRepeatTask?.cancel()
        deleteRepeatTask = nil
    }

    func keyUp(_ key: Key) {
        switch key {
        case .character(let character):
            if ".,?!".contains(character) { autocorrectLastWord() }
            proxy.insertText(shift == .off ? character : character.uppercased())
            if character == "'" { layout = .letters }
        case .space:
            insertSpace()
            layout = .letters
        case .returnKey:
            autocorrectLastWord()
            proxy.insertText("\n")
        case .shift:
            tapShift()
            return
        case .layout(let newLayout):
            layout = newLayout
            return
        case .delete, .nextKeyboard:
            return
        }
        textChangedByTyping()
    }

    func textDidChange() {
        updateAutoCapitalization()
    }

    private func deleteBackward() {
        proxy.deleteBackward()
        textChangedByTyping()
    }

    private func textChangedByTyping() {
        polishTask?.cancel()
        undo = nil
        noticeTask?.cancel()
        notice = nil
        if shift == .once { shift = .off }
        updateAutoCapitalization()
    }

    private func tapShift() {
        let now = Date()
        if shift == .once, now.timeIntervalSince(lastShiftTap) < 0.35 {
            shift = .locked
        } else {
            shift = shift == .off ? .once : .off
        }
        lastShiftTap = now
    }

    /// Two spaces after a word become ". ", like the system keyboard.
    private func insertSpace() {
        let before = proxy.documentContextBeforeInput ?? ""
        if before.hasSuffix(" "), let previous = before.dropLast().last, previous.isLetter || previous.isNumber {
            proxy.deleteBackward()
            proxy.insertText(". ")
            return
        }
        autocorrectLastWord()
        proxy.insertText(" ")
    }

    private func autocorrectLastWord() {
        guard proxy.autocorrectionType != .no else { return }
        let before = proxy.documentContextBeforeInput ?? ""
        let word = String(before.reversed().prefix { $0.isLetter }.reversed())
        guard let correction = Autocorrect.correction(for: word), correction != word else { return }
        for _ in 0..<word.count { proxy.deleteBackward() }
        proxy.insertText(correction)
    }

    private func updateAutoCapitalization() {
        guard shift != .locked else { return }
        guard proxy.autocapitalizationType != UITextAutocapitalizationType.none else {
            shift = .off
            return
        }
        let before = proxy.documentContextBeforeInput ?? ""
        let trimmed = before.replacingOccurrences(of: " ", with: "")
        let startsSentence = trimmed.isEmpty
            || before.hasSuffix("\n")
            || (before.hasSuffix(" ") && ".!?".contains(trimmed.last!))
        shift = startsSentence ? .once : .off
    }

    // MARK: - Polish

    func selectStyle(_ style: PolishStyle) {
        selectedStyle = style
        AppGroup.defaults.set(style.id, forKey: SettingsKeys.defaultStyle)
        isPickingStyle = false
    }

    func polish() {
        guard hasFullAccess, notice != .polishing else { return }
        let jws = AppGroup.defaults.string(forKey: SettingsKeys.cloudEntitlementJWS)
        let style = selectedStyle
        AppGroup.defaults.set(style.id, forKey: SettingsKeys.defaultStyle)
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
                undo = (text, result.text)
                show(.polished)
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
        self.undo = nil
        notice = nil
        updateAutoCapitalization()
    }

    // MARK: - App handoff

    func record() {
        guard hasFullAccess else { return }
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
        proxy.insertText(text)
        updateAutoCapitalization()
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
