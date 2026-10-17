import UIKit
import XCTest

/// A text field as a keyboard sees it: only the sentence around the cursor
/// shared, or all of it when `sharesEverything`.
@MainActor
private final class FakeHost: NSObject, UITextDocumentProxy {
    private let text: NSString
    private let sharesEverything: Bool
    private(set) var cursor: Int
    private(set) var moves: [Int] = []

    init(text: String, cursor: Int, sharesEverything: Bool = false) {
        self.text = text as NSString
        self.cursor = cursor
        self.sharesEverything = sharesEverything
    }

    private func isSentenceStart(_ index: Int) -> Bool {
        guard index > 0 else { return true }
        if text.character(at: index - 1) == 10 { return true }
        guard index > 1, text.character(at: index - 1) == 32 else { return false }
        return [46, 33, 63].contains(text.character(at: index - 2))
    }

    var documentContextBeforeInput: String? {
        if sharesEverything { return text.substring(to: cursor) }
        guard cursor > 0, text.character(at: cursor - 1) != 10 else { return "" }
        // Back to the start of the sentence holding the character before the cursor.
        var start = cursor - 1
        while !isSentenceStart(start) { start -= 1 }
        return text.substring(with: NSRange(location: start, length: cursor - start))
    }

    var documentContextAfterInput: String? {
        if sharesEverything { return text.substring(from: cursor) }
        var end = cursor
        while end < text.length, text.character(at: end) != 10, !(end > cursor && isSentenceStart(end)) { end += 1 }
        return text.substring(with: NSRange(location: cursor, length: end - cursor))
    }

    func adjustTextPosition(byCharacterOffset offset: Int) {
        cursor = min(max(cursor + offset, 0), text.length)
        moves.append(cursor)
    }

    var selectedText: String? { nil }
    var documentInputMode: UITextInputMode? { nil }
    var documentIdentifier: UUID { UUID() }
    var hasText: Bool { text.length > 0 }
    func setMarkedText(_ markedText: String, selectedRange: NSRange) {}
    func unmarkText() {}
    func insertText(_ text: String) {}
    func deleteBackward() {}
}

@MainActor
final class FloatingCursorTests: XCTestCase {
    private static let width: CGFloat = 340
    private static let lineHeight = TrackpadLayout.font.lineHeight

    private static let paragraph = [
        "Every word here sits in one long paragraph with no line breaks at all, so only wrapping makes rows.",
        "The river behind the old mill runs quiet in late summer, low enough to cross on the flat stones.",
        "Nobody remembers who built the footbridge, but everyone has an opinion about who should fix it.",
        "On Saturdays the market fills the square with folding tables, hand-painted signs, and arguments over plums.",
        "A man with a cart sells lemonade for a dollar and tells anyone who listens about his time at sea.",
        "By late afternoon the shadows stretch across the cobblestones and the vendors start packing crates.",
    ].joined(separator: " ")

    private static let prose = """
    The morning started slowly with coffee on the porch and a long list of errands that never seemed to get shorter.

    By noon the sun was high, the dog had found three new places to nap, and the neighbors were already arguing.

    We drove into town after lunch. The hardware store was out of the hinges we needed, so we wandered through the market.
    """

    /// Holds space and drags by `delta` the way a finger does, in small steps,
    /// then lifts and waits for any read to finish.
    private func drag(_ host: FakeHost, by delta: CGVector) async -> FloatingCursor {
        var shown: (layout: TrackpadLayout, caret: Int)?
        let cursor = FloatingCursor(proxy: host, width: Self.width) { shown = ($0, $1) }
        let steps = max(1, Int((max(abs(delta.dx), abs(delta.dy)) / 1.5).rounded(.up)))
        for _ in 0..<steps {
            cursor.move(by: CGVector(dx: delta.dx / CGFloat(steps), dy: delta.dy / CGFloat(steps)))
            try? await Task.sleep(for: .milliseconds(4))
        }
        cursor.end()
        var settled: Int
        repeat {
            settled = host.moves.count
            try? await Task.sleep(for: .milliseconds(80))
        } while host.moves.count != settled
        XCTAssertTrue(shown!.layout === cursor.layout && shown!.caret == cursor.cursor, "the panel shows a stale cursor")
        return cursor
    }

    /// The lines a vertical drag crosses: none until it's past the line's
    /// edge plus the margin, then one per line height.
    private func expectedLines(_ distance: CGFloat) -> Int {
        let threshold = Self.lineHeight * 0.8
        guard abs(distance) > threshold else { return 0 }
        let lines = 1 + Int((abs(distance) - threshold) / Self.lineHeight)
        return distance < 0 ? -lines : lines
    }

    /// With the whole text in the panel, every drag lands exactly as many
    /// panel lines away as the finger traveled, on the character nearest
    /// straight above or below.
    func testDragsMoveByThePanelsLines() async {
        for text in [Self.paragraph, Self.prose] {
            let layout = TrackpadLayout(text: text, width: Self.width)
            for start in stride(from: 33, to: (text as NSString).length, by: 67) {
                for distance: CGFloat in [-14, 14, -26, 26, -48, 48, -90, 90] {
                    let host = FakeHost(text: text, cursor: start, sharesEverything: true)
                    _ = await drag(host, by: CGVector(dx: 0, dy: distance))
                    let target = min(max(layout.line(of: start) + expectedLines(distance), 0), layout.lineCount - 1)
                    XCTAssertEqual(layout.line(of: host.cursor), target, "from \(start) by \(distance)pt")
                    let reach = layout.indexes(onLine: target).map { layout.caretX(at: $0) }
                    if (reach.min()!...reach.max()!).contains(layout.caretX(at: start)) {
                        XCTAssertEqual(layout.caretX(at: host.cursor), layout.caretX(at: start), accuracy: 9, "from \(start) by \(distance)pt")
                    }
                }
            }
        }
    }

    /// Hosts share only the sentence around the cursor; going up past it reads
    /// the rest in, across sentences and paragraphs, up to the start.
    func testLongDragsReadTheWholeText() async {
        for text in [Self.paragraph, Self.prose] {
            let host = FakeHost(text: text, cursor: (text as NSString).length)
            let cursor = await drag(host, by: CGVector(dx: 0, dy: -Self.lineHeight * 30))
            XCTAssertEqual(cursor.text, text)
            XCTAssertEqual(cursor.layout.line(of: host.cursor), 0)
        }
    }

    /// Sideways, the cursor stays on its line and goes one and a half times
    /// as far as the finger.
    func testSidewaysDragsStayOnTheLine() async {
        let layout = TrackpadLayout(text: Self.paragraph, width: Self.width)
        let start = layout.indexes(onLine: 3).lowerBound + 5
        let host = FakeHost(text: Self.paragraph, cursor: start, sharesEverything: true)
        _ = await drag(host, by: CGVector(dx: 60, dy: 4))
        XCTAssertEqual(layout.line(of: host.cursor), 3)
        XCTAssertEqual(layout.caretX(at: host.cursor) - layout.caretX(at: start), 90, accuracy: 9)
    }
}
