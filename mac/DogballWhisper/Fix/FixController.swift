import AppKit

enum FixError: LocalizedError, Equatable {
    case noSelection
    case accessibilityRequired
    case emptyResponse
    case pasteFailed

    var errorDescription: String? {
        switch self {
        case .noSelection:
            return "No text to fix. Select text (or copy it to the clipboard) and try again."
        case .accessibilityRequired:
            return "Accessibility permission required. Open System Settings → Privacy & Security → Accessibility."
        case .emptyResponse:
            return "\(S1Mini.displayName) returned no corrected text."
        case .pasteFailed:
            return "The app you were in lost focus or is in a password field, so the fix was copied to the clipboard instead."
        }
    }
}

/// The text ⌘⇧1 was pressed on, and where the fix goes back to.
struct FixTarget: Equatable {
    let originalText: String
    let sourcePID: pid_t?
    /// False when nothing was selected and the text came from the clipboard:
    /// accepting then copies the fix instead of pasting it.
    let replacesSelection: Bool

    /// The model trims its answer, but a selection often carries the newline
    /// at the end of a triple-clicked paragraph. Putting the original's
    /// leading and trailing whitespace back keeps Replace from joining that
    /// paragraph onto the next one.
    func restoringSurroundingWhitespace(_ fixed: String) -> String {
        let leading = originalText.prefix { $0.isWhitespace }
        let trailing = originalText.reversed().prefix { $0.isWhitespace }.reversed()
        guard leading.count < originalText.count else { return fixed }
        return leading + fixed + String(trailing)
    }
}

protocol TextFixing: Sendable {
    func fix(_ text: String, onText: @escaping @Sendable (String) -> Void) async throws -> String
}

@MainActor
protocol SelectionAccessing: AnyObject {
    /// Copies the frontmost app's selection, falling back to the clipboard.
    func capture() async throws -> FixTarget
    /// Pastes `text` over the selection the target was captured from.
    func replace(_ target: FixTarget, with text: String) async throws
    func copyToClipboard(_ text: String)
    /// Gives focus back to the app the target came from.
    func returnFocus(to target: FixTarget)
}

@MainActor
protocol FixPresenting: AnyObject {
    var onAccept: (() -> Void)? { get set }
    var onDismiss: (() -> Void)? { get set }
    var onCancel: (() -> Void)? { get set }
    func showLoading(title: String, subtitle: String)
    func updateStreaming(text: String)
    func showResult(original: String, fixed: String, acceptTitle: String)
    func showError(_ message: String)
    func hide()
}

/// ⌘⇧1, as the Fixit app does it: copy the selection, show a dialog while
/// the model works, then show the edit for review with Replace, Copy and
/// Dismiss. The model is S1-mini on this Mac rather than a cloud provider.
@MainActor
final class FixController {
    private let selection: SelectionAccessing
    private let fixer: TextFixing
    private let presenter: FixPresenting
    private let isModelInstalled: () -> Bool
    private(set) var isProcessing = false
    private var currentFixTask: Task<Void, Never>?

    init(
        selection: SelectionAccessing,
        fixer: TextFixing,
        presenter: FixPresenting,
        isModelInstalled: @escaping () -> Bool = { S1Mini.isInstalled }
    ) {
        self.selection = selection
        self.fixer = fixer
        self.presenter = presenter
        self.isModelInstalled = isModelInstalled
    }

    /// Returns the task doing the work, so tests can wait for it.
    @discardableResult
    func trigger() -> Task<Void, Never>? {
        guard !isProcessing else { return nil }
        isProcessing = true
        return Task { @MainActor in
            defer { isProcessing = false }
            // Checked before touching the clipboard, the way Fixit checks for
            // an API key, so a missing model costs nothing.
            guard isModelInstalled() else {
                presenter.onCancel = nil
                presenter.onDismiss = nil
                presenter.showError(S1MiniError.notInstalled.localizedDescription)
                return
            }
            do {
                let target = try await selection.capture()
                await performFix(target)
            } catch {
                presenter.onCancel = nil
                presenter.onDismiss = nil
                presenter.showError(error.localizedDescription)
            }
        }
    }

    private func performFix(_ target: FixTarget) async {
        presenter.onCancel = { [weak self] in
            self?.currentFixTask?.cancel()
            self?.selection.returnFocus(to: target)
        }
        presenter.showLoading(
            title: target.replacesSelection ? "Fixing selected text…" : "Fixing clipboard text…",
            subtitle: "Running \(S1Mini.displayName) on this Mac")
        let task = Task { @MainActor in
            do {
                let presenter = self.presenter
                let fixed = try await fixer.fix(target.originalText) { text in
                    Task { @MainActor in presenter.updateStreaming(text: text) }
                }
                try Task.checkCancellation()
                showResult(target.restoringSurroundingWhitespace(fixed), for: target)
            } catch is CancellationError {
                presenter.hide()
            } catch {
                presenter.onCancel = nil
                presenter.onDismiss = nil
                Diagnostics.log("fix: failed: \(Diagnostics.describe(error))")
                presenter.showError(error.localizedDescription)
            }
        }
        currentFixTask = task
        await task.value
        currentFixTask = nil
    }

    private func showResult(_ fixed: String, for target: FixTarget) {
        presenter.onCancel = nil
        presenter.onAccept = { [weak self] in
            guard let self else { return }
            guard target.replacesSelection else {
                self.selection.copyToClipboard(fixed)
                self.selection.returnFocus(to: target)
                return
            }
            Task { @MainActor in
                do {
                    try await self.selection.replace(target, with: fixed)
                } catch {
                    self.presenter.onDismiss = nil
                    self.presenter.showError(error.localizedDescription)
                }
            }
        }
        presenter.onDismiss = { [weak self] in self?.selection.returnFocus(to: target) }
        presenter.showResult(
            original: target.originalText,
            fixed: fixed,
            acceptTitle: target.replacesSelection ? "Replace" : "Copy to Clipboard")
    }
}
