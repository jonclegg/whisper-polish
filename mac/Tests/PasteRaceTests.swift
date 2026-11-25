import XCTest
@testable import DogballWhisper

/// Drives the real `insert()` against a private pasteboard, with the posted
/// ⌘V replaced by a simulated target app that reads the pasteboard some time
/// later — the way a real app does once its main thread gets to the event.
final class PasteRaceTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: .init("com.jonclegg.DogballWhisper.tests.paste"))
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        super.tearDown()
    }

    private func inserter(targetReadsAfter delay: TimeInterval, read: @escaping (String?) -> Void)
        -> PasteboardTextInserter
    {
        let pasteboard = pasteboard!
        return PasteboardTextInserter(
            secureInputProvider: { false },
            pasteboard: pasteboard,
            isTrusted: { true },
            postPaste: {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    read(pasteboard.string(forType: .string))
                }
            })
    }

    private func waitForClipboard(_ expected: String, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while pasteboard.string(forType: .string) != expected, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(pasteboard.string(forType: .string), expected)
    }

    func testAFastTargetPastesTheDictation() {
        let pasted = expectation(description: "target read the pasteboard")
        var got: String?
        let sut = inserter(targetReadsAfter: 0.01) { got = $0; pasted.fulfill() }

        XCTAssertEqual(sut.insert("dictated", targetPID: nil, mode: .paste), .pasted)
        wait(for: [pasted], timeout: 2)
        XCTAssertEqual(got, "dictated")
        waitForClipboard("original", timeout: 3)
    }

    // The reported bug: under load the target app gets to the ⌘V after the
    // clipboard has already been put back, and pastes the old contents.
    func testASlowTargetStillPastesTheDictationNotTheOldClipboard() {
        let pasted = expectation(description: "target read the pasteboard")
        var got: String?
        let sut = inserter(targetReadsAfter: 0.8) { got = $0; pasted.fulfill() }

        XCTAssertEqual(sut.insert("dictated", targetPID: nil, mode: .paste), .pasted)
        wait(for: [pasted], timeout: 3)
        XCTAssertEqual(got, "dictated")
        waitForClipboard("original", timeout: 3)
    }

    // ⌘V swallowed by something that never pastes: the user's clipboard must
    // still come back rather than staying lent out forever.
    func testAPasteNobodyReadsStillRestoresTheClipboard() {
        let sut = PasteboardTextInserter(
            secureInputProvider: { false }, pasteboard: pasteboard, isTrusted: { true },
            postPaste: {}, readTimeout: 0.3)

        XCTAssertEqual(sut.insert("dictated", targetPID: nil, mode: .paste), .pasted)
        waitForClipboard("original", timeout: 3)
    }

    // Clipboard managers that follow nspasteboard.org skip transient items,
    // so they neither keep the dictation in their history nor read it early.
    func testTheDictationIsMarkedTransientForClipboardManagers() {
        let sut = inserter(targetReadsAfter: 10) { _ in }

        _ = sut.insert("dictated", targetPID: nil, mode: .paste)
        XCTAssertEqual(
            pasteboard.pasteboardItems?.first?.types.contains(PasteboardTextInserter.transientType),
            true)
    }

    // A second dictation while the first still has the clipboard on loan must
    // not treat the first dictation as what the user had copied.
    func testBackToBackDictationsStillRestoreTheUsersClipboard() {
        let first = expectation(description: "first read")
        let second = expectation(description: "second read")
        var reads: [String?] = []
        var nextRead = first
        let sut = inserter(targetReadsAfter: 0.3) { reads.append($0); nextRead.fulfill() }

        _ = sut.insert("one", targetPID: nil, mode: .paste)
        wait(for: [first], timeout: 3)
        nextRead = second
        _ = sut.insert("two", targetPID: nil, mode: .paste)
        wait(for: [second], timeout: 3)

        XCTAssertEqual(reads, ["one", "two"])
        waitForClipboard("original", timeout: 3)
    }

    // Clipboard-only mode is the user's to paste by hand, possibly after this
    // app has quit, so it is written outright and never taken back.
    func testClipboardOnlyLeavesTheDictationInPlace() {
        let sut = inserter(targetReadsAfter: 0) { _ in XCTFail("must not paste") }

        XCTAssertEqual(
            sut.insert("dictated", targetPID: nil, mode: .clipboardOnly), .copiedToClipboard)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(pasteboard.string(forType: .string), "dictated")
    }
}
