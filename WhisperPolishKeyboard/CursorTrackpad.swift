import CoreGraphics

/// Space-bar drags. Horizontal drags walk characters. Vertical drags change
/// lines and keep the column, the way the iPhone trackpad does.
///
/// A keyboard can't draw a floating cursor in the host app, so between two
/// lines the caret glides through the characters that separate them instead
/// of jumping when a line's worth of travel builds up.
///
/// A keyboard also can't see the field's soft wraps, so a run of text longer
/// than `visualLineLength` is treated as several rows. Hard returns are real
/// lines. The host only shares the text near the caret, so running off either
/// end of it is reported, and the caller rebuilds from a fresh read.
struct CursorTrackpad {
    struct Move: Equatable {
        /// In UTF-16 units, which is what the text proxy moves by.
        var offset: Int
        var reachedEdge: Bool
    }

    private static let newline: UInt16 = 10
    private static let lowSurrogates: ClosedRange<UInt16> = 0xDC00...0xDFFF
    /// Body text is narrower than the keyboard, and a system-font character
    /// is about this wide. Used only to guess where wrapped lines break.
    private static let textWidthFraction: CGFloat = 0.8
    private static let estimatedCharacterWidth: CGFloat = 8.5

    private let visualLineLength: Int
    private let units: [UInt16]
    private(set) var preferredColumn: Int
    private var caret: Int
    private var anchor: Int
    /// Rows moved from the anchor, fractional while between two rows. Negative is up.
    private var rows: Double = 0
    private var rowsAbove: [Int] = []
    private var rowsBelow: [Int] = []
    private var rowsAboveComplete = false
    private var rowsBelowComplete = false

    init(before: String, after: String, keyboardWidth: CGFloat, preferredColumn: Int? = nil) {
        visualLineLength = Self.visualLineLength(forKeyboardWidth: keyboardWidth)
        units = Array((before + after).utf16)
        caret = before.utf16.count
        anchor = caret
        self.preferredColumn = 0
        self.preferredColumn = preferredColumn ?? columnPreference(at: caret)
    }

    static func visualLineLength(forKeyboardWidth width: CGFloat) -> Int {
        let textWidth = max(width * Self.textWidthFraction, 200)
        return max(Int((textWidth / Self.estimatedCharacterWidth).rounded()), 12)
    }

    var isAtStart: Bool { caret <= 0 }
    var isAtEnd: Bool { caret >= units.count }

    mutating func moveHorizontally(by characters: Int) -> Move {
        caret += characters
        resetVertical()
        guard contains(caret) else { return Move(offset: characters, reachedEdge: true) }
        preferredColumn = columnPreference(at: caret)
        return Move(offset: characters, reachedEdge: false)
    }

    /// Past the first row the caret runs to the start of the text, and past
    /// the last to the end, so a fresh read picks up where this one stopped.
    mutating func moveVertically(by delta: Double) -> Move {
        let start = caret
        guard contains(caret) else { return Move(offset: 0, reachedEdge: delta != 0) }
        rows += delta
        var reachedEdge = false
        if rows < 0 {
            let reachable = reachableRows(up: Int((-rows).rounded(.up)))
            if Double(reachable) < -rows {
                rows = -Double(reachable)
                reachedEdge = delta < 0
            }
        } else if rows > 0 {
            let reachable = reachableRows(down: Int(rows.rounded(.up)))
            if Double(reachable) < rows {
                rows = Double(reachable)
                reachedEdge = delta > 0
            }
        }
        let lower = Int(rows.rounded(.down))
        let fraction = rows - Double(lower)
        let from = position(row: lower)
        let to = fraction > 0 ? position(row: lower + 1) : from
        caret = snap(from + Int((Double(to - from) * fraction).rounded()))
        return Move(offset: caret - start, reachedEdge: reachedEdge)
    }

    private mutating func resetVertical() {
        anchor = caret
        rows = 0
        rowsAbove = []
        rowsBelow = []
        rowsAboveComplete = false
        rowsBelowComplete = false
    }

    private func contains(_ index: Int) -> Bool {
        index >= 0 && index <= units.count
    }

    private func position(row: Int) -> Int {
        if row < 0 { return rowsAbove[-row - 1] }
        if row > 0 { return rowsBelow[row - 1] }
        return anchor
    }

    private mutating func reachableRows(up count: Int) -> Int {
        while rowsAbove.count < count, !rowsAboveComplete {
            let from = rowsAbove.last ?? anchor
            if let next = stepRow(from: from, direction: -1) {
                rowsAbove.append(next)
            } else {
                if from != 0 { rowsAbove.append(0) }
                rowsAboveComplete = true
            }
        }
        return min(rowsAbove.count, count)
    }

    private mutating func reachableRows(down count: Int) -> Int {
        while rowsBelow.count < count, !rowsBelowComplete {
            let from = rowsBelow.last ?? anchor
            if let next = stepRow(from: from, direction: 1) {
                rowsBelow.append(next)
            } else {
                if from != units.count { rowsBelow.append(units.count) }
                rowsBelowComplete = true
            }
        }
        return min(rowsBelow.count, count)
    }

    private func stepRow(from index: Int, direction: Int) -> Int? {
        let line = hardLine(at: index)
        let length = line.end - line.start
        let row = visualRow(column: index - line.start, length: length)
        if direction < 0 {
            if row > 0 {
                return place(from: index, lineStart: line.start, lineLength: length, row: row - 1)
            }
            guard let previous = previousHardLine(before: line.start) else { return nil }
            let previousLength = previous.end - previous.start
            let lastRow = visualRow(column: previousLength, length: previousLength)
            return place(from: index, lineStart: previous.start, lineLength: previousLength, row: lastRow)
        }
        if (row + 1) * visualLineLength < length {
            return place(from: index, lineStart: line.start, lineLength: length, row: row + 1)
        }
        guard let next = nextHardLine(after: line.end) else { return nil }
        return place(from: index, lineStart: next.start, lineLength: next.end - next.start, row: 0)
    }

    private func place(from index: Int, lineStart: Int, lineLength: Int, row: Int) -> Int? {
        let rowStart = row * visualLineLength
        guard rowStart <= lineLength else { return nil }
        let room = min(visualLineLength, lineLength - rowStart)
        let next = snap(lineStart + rowStart + min(preferredColumn, room))
        return next == index ? nil : next
    }

    /// The end of a hard line that fills its last row keeps the right edge.
    /// A caret sitting on a wrap is the start of the next row.
    private func columnPreference(at index: Int) -> Int {
        let line = hardLine(at: index)
        let length = line.end - line.start
        let column = index - line.start
        if column == length, length > 0, length.isMultiple(of: visualLineLength) {
            return visualLineLength
        }
        return column % visualLineLength
    }

    private func visualRow(column: Int, length: Int) -> Int {
        if column == 0 || length == 0 { return 0 }
        return (min(column, length) - 1) / visualLineLength
    }

    private func hardLine(at index: Int) -> (start: Int, end: Int) {
        let capped = min(max(index, 0), units.count)
        let start = units[..<capped].lastIndex(of: Self.newline).map { $0 + 1 } ?? 0
        let end = units[capped...].firstIndex(of: Self.newline) ?? units.count
        return (start, end)
    }

    private func previousHardLine(before start: Int) -> (start: Int, end: Int)? {
        guard start > 0, units[start - 1] == Self.newline else { return nil }
        let end = start - 1
        let lineStart = units[..<end].lastIndex(of: Self.newline).map { $0 + 1 } ?? 0
        return (lineStart, end)
    }

    private func nextHardLine(after end: Int) -> (start: Int, end: Int)? {
        guard end < units.count, units[end] == Self.newline else { return nil }
        let start = end + 1
        return (start, units[start...].firstIndex(of: Self.newline) ?? units.count)
    }

    private func snap(_ index: Int) -> Int {
        guard index > 0, index < units.count, Self.lowSurrogates.contains(units[index]) else { return index }
        return index - 1
    }
}
