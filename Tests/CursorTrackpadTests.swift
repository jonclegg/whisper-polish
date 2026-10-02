import XCTest

final class CursorTrackpadTests: XCTestCase {
    private let phoneWidth: CGFloat = 390

    private func pad(_ before: String, _ after: String = "") -> CursorTrackpad {
        CursorTrackpad(before: before, after: after, keyboardWidth: phoneWidth)
    }

    /// Moves in small steps, like a drag, and returns every update.
    private func drag(_ pad: inout CursorTrackpad, rows: Double, steps: Int = 20) -> [CursorTrackpad.Update] {
        (0..<steps).map { _ in pad.move(columns: 0, rows: rows / Double(steps)) }
    }

    func testSidewaysMovesByCharacters() {
        var trackpad = pad("hello world", " more")
        XCTAssertEqual(trackpad.move(columns: 4, rows: 0), .init(offset: 4, edge: nil))
        XCTAssertEqual(trackpad.move(columns: -2, rows: 0), .init(offset: -2, edge: nil))
    }

    func testSidewaysStopsAtTheEndOfTheLine() {
        var trackpad = pad("abc", "\ndef")
        XCTAssertEqual(trackpad.move(columns: 5, rows: 0), .init(offset: 0, edge: nil))
        XCTAssertEqual(trackpad.move(columns: -10, rows: 0).offset, -3)
    }

    func testJumpsStraightUpInOneMoveWithoutPassingThroughTheText() {
        var trackpad = pad("abcdef\nhij")
        let offsets = drag(&trackpad, rows: -1).map(\.offset).filter { $0 != 0 }
        XCTAssertEqual(offsets, [-7])
    }

    func testChangesLineHalfwayBetweenRows() {
        var trackpad = pad("abcdef\nhij")
        XCTAssertEqual(trackpad.move(columns: 0, rows: -0.4).offset, 0)
        XCTAssertEqual(trackpad.move(columns: 0, rows: -0.2).offset, -7)
    }

    func testKeepsTheColumnAcrossAShorterLine() {
        let long = String(repeating: "a", count: 20)
        var trackpad = pad(long, "\nxy\n" + long)
        XCTAssertEqual(trackpad.move(columns: 0, rows: 1).offset, 3)
        XCTAssertEqual(trackpad.move(columns: 0, rows: 1).offset, 21)
    }

    func testMovesDiagonally() {
        var trackpad = pad("abcdef\nabcdef")
        XCTAssertEqual(trackpad.move(columns: -2, rows: -1).offset, -9)
    }

    func testWrapsAtWordsLikeATextView() {
        let rowLength = CursorTrackpad.rowLength(forKeyboardWidth: phoneWidth)
        let firstRow = String(repeating: "a", count: rowLength - 3) + " "
        var trackpad = pad(firstRow + "bcdef")
        XCTAssertEqual(trackpad.move(columns: 0, rows: -1).offset, -firstRow.count)
    }

    func testStopsOnTheFirstLineAtTheStartOfTheDocument() {
        var trackpad = pad("abc\ndef")
        _ = trackpad.move(columns: 0, rows: -1)
        let update = trackpad.move(columns: 0, rows: -1)
        XCTAssertEqual(update, .init(offset: 0, edge: .top))
        XCTAssertEqual(trackpad.probe(.top), -4)
        XCTAssertEqual(trackpad.absorb(before: "", after: "abc\ndef"), .init(offset: 3, edge: nil))
        XCTAssertEqual(trackpad.move(columns: 0, rows: -3), .init(offset: 0, edge: nil))
        XCTAssertEqual(trackpad.move(columns: 0, rows: 1).offset, 4)
    }

    func testReadsTheTextAboveTheSharedSentence() {
        var trackpad = pad("Second sentence.")
        XCTAssertEqual(trackpad.move(columns: -10, rows: -1).edge, .top)
        XCTAssertEqual(trackpad.probe(.top), -7)
        let update = trackpad.absorb(before: "First line\n", after: " Second sentence.")
        XCTAssertNil(update.edge)
        // The caret probed to just before "Second" and lands on the line above, at column 6.
        XCTAssertEqual(update.offset, -5)
    }

    func testKeepsGoingThroughSeveralReads() {
        var trackpad = pad("c")
        XCTAssertEqual(trackpad.move(columns: 0, rows: -1).edge, .top)
        _ = trackpad.probe(.top)
        var update = trackpad.absorb(before: "b", after: "\nc")
        XCTAssertNil(update.edge)
        update = trackpad.move(columns: 0, rows: -1)
        XCTAssertEqual(update.edge, .top)
        _ = trackpad.probe(.top)
        update = trackpad.absorb(before: "a", after: "\nb\nc")
        XCTAssertNil(update.edge)
        XCTAssertEqual(trackpad.move(columns: 0, rows: 2).offset, 4)
    }

    func testReadsBelowTheSharedText() {
        var trackpad = pad("abc", "")
        XCTAssertEqual(trackpad.move(columns: 0, rows: 1).edge, .bottom)
        XCTAssertEqual(trackpad.probe(.bottom), 1)
        let update = trackpad.absorb(before: "abc\n", after: "defg")
        XCTAssertEqual(update, .init(offset: 3, edge: nil))
    }

    func testIgnoresDragsWhileAReadIsPending() {
        var trackpad = pad("abc")
        _ = trackpad.move(columns: 0, rows: -1)
        _ = trackpad.probe(.top)
        XCTAssertTrue(trackpad.isProbing)
        XCTAssertEqual(trackpad.move(columns: 0, rows: -1), .init(offset: 0, edge: nil))
    }

    func testStartsOverWhenTheTextChangedUnderneath() {
        var trackpad = pad("abc")
        _ = trackpad.move(columns: 0, rows: -1)
        _ = trackpad.probe(.top)
        _ = trackpad.absorb(before: "xyz", after: "")
        XCTAssertFalse(trackpad.isProbing)
        XCTAssertEqual(trackpad.move(columns: -1, rows: 0).offset, -1)
    }

    func testNeverLandsInsideAnEmoji() {
        var trackpad = pad("a", "\n👋z")
        // Column 1 of the second line is inside the emoji.
        XCTAssertEqual(trackpad.move(columns: 0, rows: 1).offset, 1)
    }
}
