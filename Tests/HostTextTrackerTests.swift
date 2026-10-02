import XCTest

final class HostTextTrackerTests: XCTestCase {
    private let document = UUID()
    private let start = Date(timeIntervalSince1970: 1_000)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    /// Types `text` one character at a time while the host reports `reported` back.
    private func type(_ text: String, into tracker: inout HostTextTracker, reported: String, from seconds: TimeInterval) {
        for (index, character) in text.enumerated() {
            let now = at(seconds + Double(index) * 0.05)
            tracker.reconcile(reported: reported, document: document, at: now)
            tracker.willInsert(String(character), reported: reported, document: document, at: now)
        }
    }

    func testTrustsTheHostBeforeAnyEdits() {
        let tracker = HostTextTracker()
        XCTAssertEqual(tracker.textBefore(reported: "Hello"), "Hello")
        XCTAssertEqual(tracker.textBefore(reported: nil), "")
    }

    func testKeepsItsOwnTextWhileTheHostLagsBehind() {
        var tracker = HostTextTracker()
        // The host is still reporting "Let" while "Let me" is typed.
        type(" me", into: &tracker, reported: "Let", from: 0)
        tracker.reconcile(reported: "Let m", document: document, at: at(0.2))
        XCTAssertEqual(tracker.textBefore(reported: "Let m"), "Let me")
        XCTAssertEqual(TypingContext(before: tracker.textBefore(reported: "Let m")).partialWord, "me")
    }

    func testDeletesApplyToItsOwnText() {
        var tracker = HostTextTracker()
        type(" me", into: &tracker, reported: "Let", from: 0)
        tracker.willDelete(2, reported: "Let", document: document, at: at(0.2))
        XCTAssertEqual(tracker.textBefore(reported: "Let"), "Let ")
    }

    func testHandsBackToTheHostOnceItCatchesUp() {
        var tracker = HostTextTracker()
        type(" me", into: &tracker, reported: "Let", from: 0)
        tracker.reconcile(reported: "Let me", document: document, at: at(0.3))
        XCTAssertNil(tracker.local)
        XCTAssertEqual(tracker.textBefore(reported: "Let me"), "Let me")
    }

    func testCatchingUpAllowsTheHostToReportOnlyTheLastSentence() {
        var tracker = HostTextTracker()
        type(" me", into: &tracker, reported: "Hi there. Let", from: 0)
        tracker.reconcile(reported: "Let me", document: document, at: at(0.3))
        XCTAssertNil(tracker.local)
    }

    func testAStaleEmptyReportDoesNotCountAsCaughtUp() {
        var tracker = HostTextTracker()
        type("hi", into: &tracker, reported: "", from: 0)
        tracker.reconcile(reported: "", document: document, at: at(0.2))
        XCTAssertEqual(tracker.textBefore(reported: ""), "hi")
    }

    func testGivesWayWhenTheTextChangedElsewhere() {
        var tracker = HostTextTracker()
        type("hi", into: &tracker, reported: "", from: 0)
        tracker.reconcile(reported: "something else", document: document, at: at(HostTextTracker.hostLag + 1))
        XCTAssertNil(tracker.local)
    }

    func testGivesWayInAnotherTextField() {
        var tracker = HostTextTracker()
        type("hi", into: &tracker, reported: "", from: 0)
        tracker.reconcile(reported: "", document: UUID(), at: at(0.2))
        XCTAssertNil(tracker.local)
    }

    func testForgetsAfterCursorMoves() {
        var tracker = HostTextTracker()
        type("hi", into: &tracker, reported: "", from: 0)
        tracker.forget()
        XCTAssertEqual(tracker.textBefore(reported: "elsewhere"), "elsewhere")
    }

    func testKeepsOnlyRecentText() {
        var tracker = HostTextTracker()
        tracker.willInsert(String(repeating: "a", count: 1000), reported: "", document: document, at: start)
        XCTAssertEqual(tracker.local?.count, HostTextTracker.length)
    }
}
