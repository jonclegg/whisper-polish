import CoreGraphics

/// Space-bar drags steer an invisible point over the text, and the caret sits
/// on the character under it, the way the system caret follows the iPhone's
/// floating cursor. Moving between lines jumps straight there instead of
/// walking through the text in between.
///
/// A keyboard can't see the field's layout, so rows are estimated by word
/// wrapping at `rowLength` characters. Hard returns are real lines.
///
/// The host only shares the text near the caret, cut at sentences and
/// paragraphs. When the point runs past it, the caller steps the caret just
/// past the shared text with `probe`, then hands the fresh read to `absorb`,
/// which joins it to what's already known.
struct CursorTrackpad {
    enum Edge: Equatable {
        case top
        case bottom
    }

    struct Update: Equatable {
        /// In UTF-16 units, which is what the text proxy moves by.
        var offset: Int
        /// The point is past the known text, and more could be read there.
        var edge: Edge?
    }

    private struct Row {
        var start: Int
        var end: Int
        /// The last row of a hard line also owns the position after its last character.
        var isLast: Bool

        var maxColumn: Int { isLast ? end - start : max(end - start - 1, 0) }

        func contains(_ index: Int) -> Bool {
            index >= start && (index < end || (isLast && index == end))
        }
    }

    private static let newline: UInt16 = 10
    private static let space: UInt16 = 32
    private static let lowSurrogates: ClosedRange<UInt16> = 0xDC00...0xDFFF
    /// Body text is narrower than the keyboard, and a system-font character
    /// is about this wide.
    private static let textWidthFraction: CGFloat = 0.8
    private static let estimatedCharacterWidth: CGFloat = 8.5

    private let rowLength: Int
    private var units: [UInt16]
    private var rows: [Row] = []
    /// The host's caret as an index into `units`, just outside them while a probe is pending.
    private var caret: Int
    /// The point, in characters across and rows down.
    private var x: Double = 0
    private var y: Double = 0
    private var reachesDocumentStart = false
    private var reachesDocumentEnd = false

    init(before: String, after: String, keyboardWidth: CGFloat) {
        rowLength = Self.rowLength(forKeyboardWidth: keyboardWidth)
        units = Array((before + after).utf16)
        caret = before.utf16.count
        layOut()
        let row = rowIndex(containing: caret)
        x = Double(caret - rows[row].start)
        y = Double(row)
    }

    static func rowLength(forKeyboardWidth width: CGFloat) -> Int {
        let textWidth = max(width * Self.textWidthFraction, 200)
        return max(Int((textWidth / Self.estimatedCharacterWidth).rounded()), 12)
    }

    var isProbing: Bool { caret < 0 || caret > units.count }

    mutating func move(columns: Double, rows down: Double) -> Update {
        x = min(max(x + columns, 0), Double(rowLength))
        y += down
        guard !isProbing else { return Update(offset: 0, edge: nil) }
        return settle()
    }

    /// Steps the caret one character past the known text, so the host shares what lies beyond.
    mutating func probe(_ edge: Edge) -> Int {
        let target = edge == .top ? -1 : units.count + 1
        defer { caret = target }
        return target - caret
    }

    /// Joins a fresh read of the host's text, then puts the caret back under the point.
    mutating func absorb(before: String, after: String) -> Update {
        let fresh = Array((before + after).utf16)
        let host = before.utf16.count
        let anchorRow = currentRow
        let anchor = rows[anchorRow].start
        let rowsFromAnchor = y - Double(anchorRow)

        // A probe at either end of the document leaves the caret where it was.
        let clamped = min(max(caret, 0), units.count)
        let mayBeAtAnEnd = (caret < 0 && before.isEmpty) || (caret > units.count && after.isEmpty)
        let candidates = mayBeAtAnEnd ? [clamped, caret] : [caret]
        guard let assumed = candidates.first(where: { agrees(fresh, host: host, assumingCaret: $0) }) else {
            units = fresh
            caret = host
            reachesDocumentStart = false
            reachesDocumentEnd = false
            layOut()
            y = Double(rowIndex(containing: caret)) + rowsFromAnchor
            return settle()
        }
        if assumed != caret {
            if caret < 0 { reachesDocumentStart = true } else { reachesDocumentEnd = true }
        }

        let shift = host - assumed
        let low = min(0, shift)
        let high = max(fresh.count, shift + units.count)
        units = (low..<high).map { index in
            let old = index - shift
            return old >= 0 && old < units.count ? units[old] : fresh[index]
        }
        caret = host - low
        layOut()
        y = Double(rowIndex(containing: anchor + shift - low)) + rowsFromAnchor
        return settle()
    }

    private var currentRow: Int {
        min(max(Int(y.rounded()), 0), rows.count - 1)
    }

    private mutating func settle() -> Update {
        var edge: Edge?
        let last = Double(rows.count - 1)
        if y < -0.5 {
            if reachesDocumentStart {
                y = 0
            } else {
                edge = .top
                y = max(y, -1)
            }
        } else if y > last + 0.5 {
            if reachesDocumentEnd {
                y = last
            } else {
                edge = .bottom
                y = min(y, last + 1)
            }
        }
        let row = rows[currentRow]
        let target = snap(row.start + min(Int(x.rounded()), row.maxColumn))
        defer { caret = target }
        return Update(offset: target - caret, edge: edge)
    }

    /// Whether the fresh read touches the known text and matches it wherever the two overlap.
    private func agrees(_ fresh: [UInt16], host: Int, assumingCaret assumed: Int) -> Bool {
        let shift = host - assumed
        guard shift <= fresh.count, shift + units.count >= 0 else { return false }
        let lower = max(0, -shift)
        let upper = min(units.count, fresh.count - shift)
        guard lower < upper else { return true }
        return (lower..<upper).allSatisfy { units[$0] == fresh[$0 + shift] }
    }

    private mutating func layOut() {
        rows = []
        var lineStart = 0
        for index in units.indices where units[index] == Self.newline {
            wrap(lineStart, index)
            lineStart = index + 1
        }
        wrap(lineStart, units.count)
    }

    /// Greedy word wrap, like a text view's.
    private mutating func wrap(_ lineStart: Int, _ lineEnd: Int) {
        var start = lineStart
        while lineEnd - start > rowLength {
            let limit = start + rowLength
            let next: Int
            if units[limit] == Self.space {
                next = limit + 1
            } else if let space = units[start..<limit].lastIndex(of: Self.space), space > start {
                next = space + 1
            } else {
                next = limit
            }
            rows.append(Row(start: start, end: next, isLast: false))
            start = next
        }
        rows.append(Row(start: start, end: lineEnd, isLast: true))
    }

    private func rowIndex(containing index: Int) -> Int {
        if index <= 0 { return 0 }
        return rows.firstIndex { $0.contains(index) } ?? rows.count - 1
    }

    private func snap(_ index: Int) -> Int {
        guard index > 0, index < units.count, Self.lowSurrogates.contains(units[index]) else { return index }
        return index - 1
    }
}
