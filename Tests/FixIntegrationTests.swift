import AppKit
import XCTest
@testable import DogballWhisper

/// Renders each state of the ⌘⇧1 dialog to a PNG, to look at:
/// RUN_FIX_PANEL_IT=1 ./scripts/test.sh DogballWhisperTests/FixPanelSnapshotTests
/// The paths are printed in the test log.
@MainActor
final class FixPanelSnapshotTests: XCTestCase {
    func testRendersEachState() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_FIX_PANEL_IT"] == "1")
        let panel = FixOverlayPanel()
        defer { panel.hide() }

        panel.showLoading(title: "Fixing selected text…", subtitle: "Running \(S1Mini.displayName) on this Mac")
        panel.updateStreaming(text: "I agree with you, we should")
        try snapshot(panel, "loading")

        panel.showResult(
            original: "lets create a new project on this folder",
            fixed: "Let's create a new project in this folder.",
            acceptTitle: "Replace")
        try snapshot(panel, "result")

        panel.showResult(original: "Same text.", fixed: "Same text.", acceptTitle: "Copy to Clipboard")
        try snapshot(panel, "unchanged")

        panel.showError(FixError.noSelection.localizedDescription)
        try snapshot(panel, "error")
    }

    private func snapshot(_ panel: NSPanel, _ name: String) throws {
        panel.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let view = try XCTUnwrap(panel.contentView?.superview)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fix-panel-\(name).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        print("FIX_PANEL_SNAPSHOT \(url.path)")
    }
}

/// The whole of ⌘⇧1 for real, inside the test host's own window: a real key
/// press through the real event tap, a real ⌘C, real S1-mini, the real
/// dialog accepted with a real Return, and a real ⌘V back into the text.
/// Needs S1-mini installed and Accessibility granted to this build, and takes
/// focus for a few seconds while it runs:
/// RUN_FIX_E2E=1 ./scripts/test.sh DogballWhisperTests/FixEndToEndTests
@MainActor
final class FixEndToEndTests: XCTestCase {
    private static let returnKey: CGKeyCode = 36

    func testCommandShiftOneFixesTheSelectionInPlace() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_FIX_E2E"] == "1")
        XCTAssertTrue(AXIsProcessTrusted(), "grant this build Accessibility first")
        XCTAssertTrue(S1Mini.isInstalled, "download S1-mini first")

        let clipboardBefore = "clipboard \(UUID().uuidString)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(clipboardBefore, forType: .string)

        let selected = "I am agree with you, we should to make the meeting in monday.\n"
        let rest = "This line is not selected."
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 600, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        let textView = NSTextView(frame: window.contentLayoutRect)
        textView.string = selected + rest
        window.contentView = textView
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 0, length: (selected as NSString).length))
        defer { window.orderOut(nil) }

        let cleaner = S1MiniCleaner()
        await cleaner.prewarm()
        let panel = SpyPresenter()
        let controller = FixController(
            selection: PasteboardSelection(inserter: PasteboardTextInserter()),
            fixer: cleaner, presenter: panel)
        let monitor = HotkeyMonitor(binding: .rightOption) { _ in }
        monitor.onFixShortcut = { MainActor.assumeIsolated { controller.trigger() } }
        try monitor.start()
        defer { monitor.stop() }

        try await waitUntil("this app is frontmost") {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
                == ProcessInfo.processInfo.processIdentifier && window.isKeyWindow
        }
        Self.post(keyCode: CGKeyCode(FixShortcut.keyCode), flags: [.maskCommand, .maskShift])

        try await waitUntil("the dialog shows the edit") { panel.shownResult != nil }
        let result = try XCTUnwrap(panel.shownResult)
        XCTAssertEqual(result.original, selected)
        XCTAssertEqual(result.acceptTitle, "Replace")
        XCTAssertTrue(panel.panel.isKeyWindow, "Return has to reach the dialog")
        // The selection was copied without costing the user their clipboard.
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), clipboardBefore)

        Self.post(keyCode: Self.returnKey, flags: [])
        try await waitUntil("the fix is pasted") { textView.string != selected + rest }
        XCTAssertEqual(textView.string, result.fixed + rest)
        XCTAssertTrue(result.fixed.hasPrefix("I"), result.fixed)
        XCTAssertTrue(result.fixed.hasSuffix("\n"), "the selection's newline is kept")
        XCTAssertNotEqual(result.fixed, selected)
        print("FIX_E2E fixed: \(result.fixed)")

        try await waitUntil("the clipboard is given back") {
            NSPasteboard.general.string(forType: .string) == clipboardBefore
        }
    }

    private static func post(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    private func waitUntil(
        _ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw TimedOut(what: what) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

private struct TimedOut: Error {
    let what: String
}

/// The real dialog, recording what it was asked to show.
@MainActor
private final class SpyPresenter: FixPresenting {
    let panel = FixOverlayPanel()
    private(set) var shownResult: (original: String, fixed: String, acceptTitle: String)?

    var onAccept: (() -> Void)? {
        get { panel.onAccept }
        set { panel.onAccept = newValue }
    }
    var onDismiss: (() -> Void)? {
        get { panel.onDismiss }
        set { panel.onDismiss = newValue }
    }
    var onCancel: (() -> Void)? {
        get { panel.onCancel }
        set { panel.onCancel = newValue }
    }

    func showLoading(title: String, subtitle: String) { panel.showLoading(title: title, subtitle: subtitle) }
    func updateStreaming(text: String) { panel.updateStreaming(text: text) }
    func showResult(original: String, fixed: String, acceptTitle: String) {
        shownResult = (original, fixed, acceptTitle)
        panel.showResult(original: original, fixed: fixed, acceptTitle: acceptTitle)
    }
    func showError(_ message: String) {
        XCTFail("the dialog showed an error: \(message)")
        panel.showError(message)
    }
    func hide() { panel.hide() }
}
