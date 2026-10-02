import XCTest

final class CursorTrackpadTests: XCTestCase {
    /// About 37 characters a row.
    private let phoneWidth: CGFloat = 390

    private func pad(_ before: String, _ after: String = "", width: CGFloat = 390) -> CursorTrackpad {
        CursorTrackpad(before: before, after: after, keyboardWidth: width)
    }

    /// Moves vertically in small steps, like a drag.
    private func drag(_ pad: inout CursorTrackpad, rows: Double, steps: Int = 20) -> (offsets: [Int], reachedEdge: Bool) {
        var offsets: [Int] = []
        var reachedEdge = false
        for _ in 0..<steps {
            let move = pad.moveVertically(by: rows / Double(steps))
            offsets.append(move.offset)
            reachedEdge = reachedEdge || move.reachedEdge
        }
        return (offsets, reachedEdge)
    }

    func testHorizontalMovesAreCharacters() {
        var trackpad = pad("hello world", " more")
        XCTAssertEqual(trackpad.moveHorizontally(by: 4), .init(offset: 4, reachedEdge: false))
        XCTAssertEqual(trackpad.moveHorizontally(by: -2), .init(offset: -2, reachedEdge: false))
    }

    func testHorizontalMovesPastTheSharedTextAskForAFreshRead() {
        var trackpad = pad("hi")
        XCTAssertEqual(trackpad.moveHorizontally(by: -5), .init(offset: -5, reachedEdge: true))
        XCTAssertEqual(trackpad.moveVertically(by: -1), .init(offset: 0, reachedEdge: true))
    }

    func testAWholeRowUpKeepsTheColumn() {
        var trackpad = pad("abcdef\nhij")
        XCTAssertEqual(trackpad.moveVertically(by: -1), .init(offset: -7, reachedEdge: false))
        XCTAssertEqual(trackpad.moveVertically(by: 1), .init(offset: 7, reachedEdge: false))
    }

    func testGlidesThroughTheCharactersBetweenRows() {
        var trackpad = pad("abcdef\nhij")
        let (offsets, _) = drag(&trackpad, rows: -1)
        XCTAssertEqual(offsets.reduce(0, +), -7)
        // Seven characters spread over twenty small steps: never more than one at a time.
        XCTAssertTrue(offsets.allSatisfy { $0 == 0 || $0 == -1 })
        XCTAssertEqual(offsets.filter { $0 != 0 }.count, 7)
    }

    func testAShorterLineDoesNotLoseTheColumn() {
        let long = String(repeating: "a", count: 20)
        var trackpad = pad(long, "\nxy\n" + long)
        XCTAssertEqual(trackpad.moveVertically(by: 1).offset, 3)
        XCTAssertEqual(trackpad.moveVertically(by: 1).offset, 21)
    }

    func testWrappedRowsCountAsLines() {
        let line = String(repeating: "abcdefghij", count: 4)
        let rowLength = CursorTrackpad.visualLineLength(forKeyboardWidth: phoneWidth)
        var trackpad = pad(String(line.prefix(rowLength + 3)), String(line.dropFirst(rowLength + 3)))
        XCTAssertEqual(trackpad.moveVertically(by: -1).offset, -rowLength)
    }

    func testRunsToTheStartAboveTheFirstLineAndReportsTheEdge() {
        var trackpad = pad("abc\ndefgh")
        XCTAssertEqual(trackpad.moveVertically(by: -1).offset, -6)
        let move = trackpad.moveVertically(by: -3)
        XCTAssertEqual(move.offset, -3)
        XCTAssertTrue(move.reachedEdge)
        XCTAssertTrue(trackpad.isAtStart)
    }

    func testRunsToTheEndBelowTheLastLine() {
        var trackpad = pad("abc", "defgh")
        let move = trackpad.moveVertically(by: 2)
        XCTAssertEqual(move.offset, 5)
        XCTAssertTrue(move.reachedEdge)
        XCTAssertTrue(trackpad.isAtEnd)
    }

    func testTurningBackAtTheEdgeMovesRightAway() {
        var trackpad = pad("abc\ndef")
        _ = trackpad.moveVertically(by: -10)
        XCTAssertTrue(trackpad.isAtStart)
        XCTAssertEqual(trackpad.moveVertically(by: 1).offset, 3)
    }

    func testAFreshReadKeepsThePreferredColumn() {
        var trackpad = CursorTrackpad(before: "abcdefgh", after: "", keyboardWidth: phoneWidth, preferredColumn: 3)
        XCTAssertEqual(trackpad.preferredColumn, 3)
        trackpad = CursorTrackpad(before: "ab\nabcdefgh", after: "", keyboardWidth: phoneWidth, preferredColumn: 3)
        XCTAssertEqual(trackpad.moveVertically(by: -1).offset, -9)
    }

    func testNeverLandsInsideAnEmoji() {
        var trackpad = CursorTrackpad(before: "abcdef", after: "\n👋z", keyboardWidth: phoneWidth, preferredColumn: 1)
        let move = trackpad.moveVertically(by: 1)
        XCTAssertEqual(move.offset, 1)
    }
}
