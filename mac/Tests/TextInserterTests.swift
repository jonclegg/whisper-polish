import XCTest
@testable import DogballWhisper

/// Covers the pure decisions extracted from `PasteboardTextInserter`: whether
/// to paste at all, and whether a delayed restore should still apply.
/// `insert()` itself is driven end to end in `PasteRaceTests`, against a
/// private pasteboard and a simulated target instead of real keystrokes.
final class TextInserterTests: XCTestCase {
    func testPastingProceedsWhenEveryGateIsOpen() {
        XCTAssertTrue(
            PasteboardTextInserter.shouldPaste(
                mode: .paste, stillFocused: true, isTrusted: true, secureInputActive: false))
    }

    func testEachGateOnItsOwnFallsBackToTheClipboard() {
        XCTAssertFalse(
            PasteboardTextInserter.shouldPaste(
                mode: .clipboardOnly, stillFocused: true, isTrusted: true,
                secureInputActive: false))
        XCTAssertFalse(
            PasteboardTextInserter.shouldPaste(
                mode: .paste, stillFocused: false, isTrusted: true, secureInputActive: false))
        XCTAssertFalse(
            PasteboardTextInserter.shouldPaste(
                mode: .paste, stillFocused: true, isTrusted: false, secureInputActive: false))
    }

    // The coordinator's own secure check ran a second or more earlier, before
    // transcription and cleanup. A `sudo` prompt appearing in that window
    // would swallow the synthetic ⌘V silently: nothing inserted, `.pasted`
    // reported anyway, and the clipboard restored afterward, leaving the
    // user with no text and no way to get it back.
    func testSecureInputEngagedSinceTheDictationStartedFallsBackToTheClipboard() {
        XCTAssertFalse(
            PasteboardTextInserter.shouldPaste(
                mode: .paste, stillFocused: true, isTrusted: true, secureInputActive: true))
    }

    func testRestoreAppliesWhenNothingElseTouchedThePasteboard() {
        XCTAssertTrue(
            PasteboardTextInserter.shouldRestore(currentChangeCount: 42, expectedChangeCount: 42)
        )
    }

    func testRestoreIsSkippedWhenTheChangeCountAdvanced() {
        // A later change count means something else -- a Cmd-C, or a second
        // dictation's own write -- now owns the pasteboard.
        XCTAssertFalse(
            PasteboardTextInserter.shouldRestore(currentChangeCount: 43, expectedChangeCount: 42)
        )
    }
}
