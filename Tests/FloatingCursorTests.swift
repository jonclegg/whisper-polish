import UIKit
import XCTest

/// A text field as a keyboard sees it: the whole text laid out at a real
/// width, but only the sentence around the cursor shared, and nothing about
/// where its lines wrap.
@MainActor
private final class FakeHost: NSObject, UITextDocumentProxy {
    private let text: NSString
    private let storage: NSTextStorage
    private let layoutManager = NSLayoutManager()
    private let container: NSTextContainer
    private(set) var cursor: Int
    private(set) var moves: [Int] = []

    init(text: String, width: CGFloat, cursor: Int) {
        self.text = text as NSString
        self.cursor = cursor
        storage = NSTextStorage(string: text, attributes: [.font: UIFont.preferredFont(forTextStyle: .body)])
        container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        super.init()
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
    }

    private var lineStarts: [Int] {
        var starts: [Int] = []
        layoutManager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)) { _, _, _, glyphs, _ in
            starts.append(self.layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil).location)
        }
        return starts
    }

    /// The visual line the cursor shows on: a wrapped line's end shows at the next line's start.
    func line(of index: Int) -> Int {
        let starts = lineStarts
        if index == text.length, index > 0, text.character(at: index - 1) == 10 { return starts.count }
        return (starts.lastIndex { $0 <= index } ?? 0)
    }

    /// How far along its line the cursor shows.
    func x(of index: Int) -> CGFloat {
        let starts = lineStarts
        let line = line(of: index)
        guard line < starts.count, index > starts[line] else { return 0 }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: starts[line], length: index - starts[line]), actualCharacterRange: nil)
        return layoutManager.boundingRect(forGlyphRange: glyphs, in: container).maxX
    }

    /// How far the line's text reaches, short of a trailing space or line break.
    func width(ofLine line: Int) -> CGFloat {
        let starts = lineStarts
        guard line < starts.count else { return 0 }
        var end = line + 1 < starts.count ? starts[line + 1] : text.length
        while end > starts[line], [10, 32].contains(text.character(at: end - 1)) { end -= 1 }
        return x(of: end)
    }

    private func isSentenceStart(_ index: Int) -> Bool {
        guard index > 0 else { return true }
        if text.character(at: index - 1) == 10 { return true }
        guard index > 1, text.character(at: index - 1) == 32 else { return false }
        return [46, 33, 63].contains(text.character(at: index - 2))
    }

    var documentContextBeforeInput: String? {
        guard cursor > 0, text.character(at: cursor - 1) != 10 else { return "" }
        // Back to the start of the sentence holding the character before the cursor.
        var start = cursor - 1
        while !isSentenceStart(start) { start -= 1 }
        return text.substring(with: NSRange(location: start, length: cursor - start))
    }

    var documentContextAfterInput: String? {
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
    private static let screenWidth: CGFloat = 420
    /// Fields from Notes' width down to Messages'.
    private static let fieldWidths: [CGFloat] = [378, 340, 296]
    private static let lineHeight = UIFont.preferredFont(forTextStyle: .body).lineHeight

    private static let paragraph = [
        "Every word here sits in one long paragraph with no line breaks at all, so only wrapping makes rows.",
        "The river behind the old mill runs quiet in late summer, low enough to cross on the flat stones.",
        "Nobody remembers who built the footbridge, but everyone has an opinion about who should fix it.",
        "On Saturdays the market fills the square with folding tables, hand-painted signs, and arguments over plums.",
        "A man with a cart sells lemonade for a dollar and tells anyone who listens about his time at sea.",
        "By late afternoon the shadows stretch across the cobblestones and the vendors start packing crates.",
        "Children chase pigeons around the fountain while their parents count change and compare tomatoes.",
        "When the bells ring at six the square empties quickly, leaving only paper bags and a few stray cats.",
    ].joined(separator: " ")

    private static let prose = """
    The morning started slowly with coffee on the porch and a long list of errands that never seemed to get shorter no matter how early we began.

    By noon the sun was high, the dog had found three new places to nap, and the neighbors were already arguing about whose turn it was to mow the strip of grass between the houses.

    We drove into town after lunch. The hardware store was out of the hinges we needed, so we wandered through the farmers market instead and came home with peaches, honey, and a basket of tomatoes far too large for two people.

    In the evening the wind picked up and rattled the screen door. We made a salad with the tomatoes, sliced the peaches over ice cream, and talked about nothing in particular until the stars came out.
    """

    /// Holds space and drags by `delta` the way a finger does, in small steps,
    /// then lifts and waits for any read to finish.
    private func drag(_ host: FakeHost, by delta: CGVector) async {
        let cursor = FloatingCursor(proxy: host, screenWidth: Self.screenWidth)
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
    }

    /// The lines a vertical drag should cross: none until it's past the line's
    /// edge plus the margin, then one per line height.
    private func expectedLines(_ distance: CGFloat) -> Int {
        let threshold = Self.lineHeight * 0.8
        guard abs(distance) > threshold else { return 0 }
        let lines = 1 + Int((abs(distance) - threshold) / Self.lineHeight)
        return distance < 0 ? -lines : lines
    }

    private struct Tally {
        var exact = 0
        var offByOne = 0
        var offByMore = 0
        /// How far sideways the cursor ended from where it started, on drags
        /// that reached the right line where that line reaches that far.
        var shifts: [CGFloat] = []
        var count: Int { exact + offByOne + offByMore }
        mutating func add(_ error: Int) {
            switch abs(error) {
            case 0: exact += 1
            case 1: offByOne += 1
            default: offByMore += 1
            }
        }
        var summary: String {
            let sorted = shifts.sorted()
            let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            let wide = Double(shifts.filter { $0 > 16 }.count) / Double(max(shifts.count, 1))
            return String(format: "%d drags: %.0f%% exact, %.0f%% off by one, %.0f%% off by two or more; sideways median %.0fpt, %.0f%% over 16pt", count, 100 * Double(exact) / Double(count), 100 * Double(offByOne) / Double(count), 100 * Double(offByMore) / Double(count), median, 100 * wide)
        }
    }

    private func measure(_ distances: [CGFloat], every spacing: Int) async -> [String: Tally] {
        var tallies: [String: Tally] = [:]
        for (name, text) in [("paragraph", Self.paragraph), ("prose", Self.prose)] {
            let length = (text as NSString).length
            for width in Self.fieldWidths {
                for start in stride(from: spacing / 2, to: length, by: spacing) {
                    for distance in distances {
                        let host = FakeHost(text: text, width: width, cursor: start)
                        let startLine = host.line(of: start)
                        await drag(host, by: CGVector(dx: 0, dy: distance))
                        let expected = expectedLines(distance)
                        let target = startLine + expected
                        let lastLine = host.line(of: length)
                        XCTAssertGreaterThan(lastLine, 10, "the host laid out no lines")
                        // At the text's first or last line there's nowhere further to go.
                        let reachable = min(max(target, 0), lastLine)
                        let error = host.line(of: host.cursor) - reachable
                        tallies["\(name) \(Int(width)) \(Int(distance))", default: Tally()].add(error)
                        tallies["all \(Int(distance))", default: Tally()].add(error)
                        let startX = host.x(of: start)
                        if error == 0, reachable == target, host.width(ofLine: target) >= startX + 8 {
                            let shift = abs(host.x(of: host.cursor) - startX)
                            tallies["\(name) \(Int(width)) \(Int(distance))"]!.shifts.append(shift)
                            tallies["all \(Int(distance))"]!.shifts.append(shift)
                        }
                    }
                }
            }
        }
        return tallies
    }

    /// A nudge of the finger leaves the cursor on its line, where it used to
    /// land a line or two away.
    func testSlightDragsStayOnTheLine() async {
        let tallies = await measure([-14, 14], every: 67)
        for distance in [-14, 14] {
            let tally = tallies["all \(distance)"]!
            XCTAssertEqual(tally.exact, tally.count, "\(distance)pt: \(tally.summary)")
        }
    }

    /// Dragging a line or two lands that many lines away most of the time, and
    /// never two lines off, whatever the field's width.
    func testLineDragsNeverLandTwoLinesOff() async {
        let tallies = await measure([-26, 26, -48, 48, -90, 90], every: 67)
        for key in tallies.keys.sorted() { print("FLOATING \(key): \(tallies[key]!.summary)") }
        for distance in [-26, 26, -48, 48] {
            let tally = tallies["all \(distance)"]!
            XCTAssertEqual(tally.offByMore, 0, "\(distance)pt: \(tally.summary)")
            XCTAssertGreaterThanOrEqual(Double(tally.exact) / Double(tally.count), 0.75, "\(distance)pt: \(tally.summary)")
        }
    }
}
