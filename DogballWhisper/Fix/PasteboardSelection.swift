import AppKit

/// Reads the selection with a synthetic ⌘C and writes the fix back with ⌘V,
/// which is how Fixit does it: copying works in every app that can copy,
/// where Accessibility's selected-text attribute is missing from Electron
/// apps, browsers and terminals.
@MainActor
final class PasteboardSelection: SelectionAccessing {
    private let pasteboard: NSPasteboard
    private let inserter: TextInserting
    private let isTrusted: () -> Bool
    private let postCopy: () -> Void

    init(
        inserter: TextInserting,
        pasteboard: NSPasteboard = .general,
        isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        postCopy: @escaping () -> Void = {
            PasteboardTextInserter.postCommand(virtualKey: PasteboardTextInserter.virtualKeyC)
        }
    ) {
        self.inserter = inserter
        self.pasteboard = pasteboard
        self.isTrusted = isTrusted
        self.postCopy = postCopy
    }

    func capture() async throws -> FixTarget {
        guard isTrusted() else { throw FixError.accessibilityRequired }
        let sourcePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        // clearContents() bumps the change count, so the baseline must come
        // from its return value.
        let clearedChangeCount = pasteboard.clearContents()
        postCopy()

        // An app with nothing selected leaves the pasteboard alone, so this
        // gives up after a second rather than waiting for a copy that is
        // never coming.
        var copied = ""
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if pasteboard.changeCount > clearedChangeCount {
                copied = pasteboard.string(forType: .string) ?? ""
                if !copied.isEmpty { break }
            }
        }
        snapshot.restore(to: pasteboard)

        if !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return FixTarget(originalText: copied, sourcePID: sourcePID, replacesSelection: true)
        }
        // Nothing selected usually means ⌘⇧1 was pressed without a
        // selection; fixing the clipboard still makes the press useful.
        let clipboard = pasteboard.string(forType: .string) ?? ""
        guard !clipboard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FixError.noSelection
        }
        return FixTarget(originalText: clipboard, sourcePID: sourcePID, replacesSelection: false)
    }

    func replace(_ target: FixTarget, with text: String) async throws {
        returnFocus(to: target)
        // Activation is asynchronous; pasting before it lands would send ⌘V
        // to this app's dialog instead.
        if let pid = target.sourcePID {
            for _ in 0..<40 where NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                try await Task.sleep(nanoseconds: 25_000_000)
            }
        }
        // The inserter refuses to paste unless that app is frontmost, outside
        // a secure field, and this app is trusted, and copies instead.
        guard inserter.insert(text, targetPID: target.sourcePID, mode: .paste) == .pasted else {
            throw FixError.pasteFailed
        }
    }

    func copyToClipboard(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func returnFocus(to target: FixTarget) {
        guard let pid = target.sourcePID,
              let app = NSRunningApplication(processIdentifier: pid),
              pid != ProcessInfo.processInfo.processIdentifier
        else { return }
        // Since macOS 14, an app only takes activation that the active app
        // hands over; the dialog made this app the active one.
        NSApp.yieldActivation(to: app)
        app.activate()
    }
}
