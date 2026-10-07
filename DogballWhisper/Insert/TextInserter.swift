import AppKit
import CoreGraphics

enum InsertOutcome: Equatable {
    case pasted
    case copiedToClipboard
}

protocol TextInserting {
    func insert(_ text: String, targetPID: pid_t?, mode: InsertionMode) -> InsertOutcome
}

/// Puts text on the clipboard, sends ⌘V to whatever is focused, then restores
/// the clipboard. Pasting is the only approach that works everywhere: native
/// apps, Electron, terminals, and web text fields all handle it identically.
///
/// The restore is driven by the paste actually happening, not by a timer.
/// ⌘V is asynchronous: the target reads the clipboard whenever its main
/// thread gets to the key event, which under load can be well after any
/// fixed delay. Restoring on a timer then hands the target the *old*
/// clipboard — it pastes whatever was copied before, or nothing at all when
/// that was empty or not text. So the dictation goes on the clipboard as a
/// promise, and the old contents come back only once the target has asked
/// for it.
final class PasteboardTextInserter: TextInserting {
    /// How long the clipboard keeps the dictation after the target has read
    /// it, for apps that read the pasteboard more than once per paste.
    static let restoreGrace: TimeInterval = 0.25

    /// How long to wait for the target to read the paste at all before giving
    /// the user their clipboard back anyway. Hitting this means the ⌘V never
    /// reached anything that pastes, so there is no dictation to protect.
    static let readTimeout: TimeInterval = 10

    /// From nspasteboard.org: tells clipboard managers the item is a
    /// transfer, not a copy, so they neither record the dictation in their
    /// history nor read it early — an early read is indistinguishable from
    /// the target's paste and would restore the clipboard too soon.
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private static let virtualKeyV: CGKeyCode = 9
    static let virtualKeyC: CGKeyCode = 8

    /// The paste the clipboard is currently lent out to, if any.
    private var pending: PendingRestore?

    /// Injected so the secure-input gate can be exercised without engaging
    /// real secure event input on the machine running the tests.
    private let secureInputProvider: () -> Bool
    private let pasteboard: NSPasteboard
    private let isTrusted: () -> Bool
    private let postPaste: () -> Void
    private let readTimeout: TimeInterval

    init(
        secureInputProvider: @escaping () -> Bool = CaretLocator.isSecureInputActive,
        pasteboard: NSPasteboard = .general,
        isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        postPaste: @escaping () -> Void = PasteboardTextInserter.postCommandV,
        readTimeout: TimeInterval = PasteboardTextInserter.readTimeout
    ) {
        self.secureInputProvider = secureInputProvider
        self.pasteboard = pasteboard
        self.isTrusted = isTrusted
        self.postPaste = postPaste
        self.readTimeout = readTimeout
    }

    func insert(_ text: String, targetPID: pid_t?, mode: InsertionMode) -> InsertOutcome {
        // A dictation landing while the previous one still has the clipboard
        // on loan must not snapshot that dictation as "what the user had
        // copied": carry the user's real clipboard forward instead, unless
        // something else has written to the pasteboard since.
        let inherited = pending.flatMap { pending in
            pasteboard.changeCount == pending.writeChangeCount ? pending.snapshot : nil
        }
        pending?.cancel()
        pending = nil

        // Pasting into the wrong window is the one unrecoverable failure, so
        // bail out to a plain copy if focus moved while we were working.
        // targetPID is nil when the caller had no target to gate on (there is
        // nothing to compare against, so there is nothing to protect against);
        // callers that care about this always pass the PID captured when
        // recording started. Do not turn a nil PID into a refusal to paste.
        let stillFocused = targetPID == nil
            || NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID
        guard Self.shouldPaste(
            mode: mode,
            stillFocused: stillFocused,
            isTrusted: isTrusted(),
            secureInputActive: secureInputProvider()
        ) else {
            // Left for the user to paste by hand, possibly after this app has
            // quit, so it is written outright rather than promised.
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return .copiedToClipboard
        }

        let snapshot = inherited ?? PasteboardSnapshot.capture(from: pasteboard)
        let promise = PromisedText(text: text)
        let item = NSPasteboardItem()
        item.setDataProvider(promise, forTypes: [.string])
        item.setData(Data(), forType: Self.transientType)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        let restore = PendingRestore(
            snapshot: snapshot, writeChangeCount: pasteboard.changeCount, promise: promise)
        promise.onRead = { [weak self, weak restore] in
            DispatchQueue.main.async {
                guard let self, let restore else { return }
                self.targetRead(restore)
            }
        }
        pending = restore

        Diagnostics.verbose("paste: posting command-V for \(text.count) characters")
        postPaste()
        schedule(restore, after: readTimeout) { [weak self] in
            Diagnostics.log(
                "paste: target never read the clipboard within \(Int(self?.readTimeout ?? 0))s, restoring it")
        }
        return .pasted
    }

    private func targetRead(_ restore: PendingRestore) {
        guard pending === restore else { return }
        Diagnostics.verbose(
            "paste: target read the clipboard after \(Int(Date().timeIntervalSince(restore.posted) * 1000))ms")
        schedule(restore, after: Self.restoreGrace) {}
    }

    /// (Re)arms the one restore for this paste: the read timeout first, then
    /// the shorter grace once the target has read.
    private func schedule(
        _ restore: PendingRestore, after delay: TimeInterval, then note: @escaping () -> Void
    ) {
        restore.timer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pending === restore else { return }
            self.pending = nil
            // Only restore if nothing else has touched the pasteboard since we
            // wrote the dictated text: someone pressing Cmd-C means the
            // pasteboard now belongs to something else and must be left alone.
            guard Self.shouldRestore(
                currentChangeCount: self.pasteboard.changeCount,
                expectedChangeCount: restore.writeChangeCount
            ) else { return }
            note()
            restore.snapshot.restore(to: self.pasteboard)
        }
        restore.timer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Whether a synthetic ⌘V may actually be posted, or whether the text
    /// should be left on the clipboard and the user told about it.
    ///
    /// The secure-input check is the one that is not obvious. The coordinator
    /// already refused to *start* a dictation into a password field, but that
    /// was a second or more ago — transcription and cleanup have run since,
    /// and in that window a `sudo` prompt can appear, Terminal's Secure
    /// Keyboard Entry can be switched on, or an authorization sheet can open.
    /// Secure input swallows synthetic keystrokes silently, so posting ⌘V
    /// into it would insert nothing, report `.pasted` anyway, dismiss the
    /// panel with no message, and then restore the clipboard, leaving the
    /// user with no text and no way to recover it.
    static func shouldPaste(
        mode: InsertionMode, stillFocused: Bool, isTrusted: Bool, secureInputActive: Bool
    ) -> Bool {
        mode == .paste && stillFocused && isTrusted && !secureInputActive
    }

    /// Whether a delayed restore should still apply. Extracted as a pure
    /// function so the gating logic is unit-testable without posting real
    /// keyboard events or touching a live pasteboard.
    static func shouldRestore(currentChangeCount: Int, expectedChangeCount: Int) -> Bool {
        currentChangeCount == expectedChangeCount
    }

    static func postCommandV() {
        postCommand(virtualKey: virtualKeyV)
    }

    static func postCommand(virtualKey: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Without this, keys the user is physically holding suppress our events.
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalKeyboardEvents, .permitLocalMouseEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        // Set flags explicitly so a still-held modifier cannot turn this into
        // some other shortcut.
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

/// One paste's claim on the clipboard: what to put back, how to tell whether
/// anything else has written since, and the timer that will put it back.
private final class PendingRestore {
    let snapshot: PasteboardSnapshot
    let writeChangeCount: Int
    /// Kept alive here rather than relying on the pasteboard item to do it.
    let promise: PromisedText
    let posted = Date()
    var timer: DispatchWorkItem?

    init(snapshot: PasteboardSnapshot, writeChangeCount: Int, promise: PromisedText) {
        self.snapshot = snapshot
        self.writeChangeCount = writeChangeCount
        self.promise = promise
    }

    func cancel() { timer?.cancel() }
}

/// The dictated text, handed over only when someone asks for it — which is
/// how the inserter learns the target has pasted.
private final class PromisedText: NSObject, NSPasteboardItemDataProvider {
    let text: String
    var onRead: (() -> Void)?

    init(text: String) { self.text = text }

    func pasteboard(
        _ pasteboard: NSPasteboard?, item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        item.setString(text, forType: type)
        onRead?()
    }
}
