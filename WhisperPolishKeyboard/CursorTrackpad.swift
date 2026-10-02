import Foundation

/// Space-bar drags. Horizontal drags walk characters. Vertical drags change
/// lines and keep the column, the way the iPhone trackpad does.
///
/// A keyboard can't see the field's soft wraps, so a run of text longer than
/// `visualLineLength` is treated as several rows. Hard returns are real lines.
struct CursorTrackpad {
    struct Move: Equatable {
        var offset: Int
        /// Vertical rows actually moved. The finger's leftover travel stays
        /// put, so dragging back from the edge of the visible text resumes
        /// where the caret stopped.
        var consumedVertical: Int
    }

    private static let newline: UInt16 = 10
    private static let lowSurrogateStart: UInt16 = 0xDC00
    private static let lowSurrogateEnd: UInt16 = 0xDFFF
    /// Body text is narrower than the keyboard, and a system-font character
    /// is about this wide. Used only to guess where wrapped lines break.
    private static let textWidthFraction: CGFloat = 0.8
    private static let estimatedCharacterWidth: CGFloat = 8.5

    private let visualLineLength: Int
    private var units: [UInt16]
    private var caret: Int
    private var preferredColumn: Int

    init(before: String, after: String, keyboardWidth: CGFloat) {
        visualLineLength = Self.visualLineLength(forKeyboardWidth: keyboardWidth)
        units = Array((before + after).utf16)
        caret = before.utf16.count
        preferredColumn = 0
        preferredColumn = columnPreference(at: caret)
    }

    static func visualLineLength(forKeyboardWidth width: CGFloat) -> Int {
        let textWidth = max(width * Self.textWidthFraction, 200)
        return max(Int((textWidth / Self.estimatedCharacterWidth).rounded()), 12)
    }

    /// `horizontal` and `vertical` are in characters and rows. Negative is
    /// left and up. The offset is UTF-16 units, which is what the text proxy
    /// moves by.
    mutating func move(horizontal: Int, vertical: Int) -> Move {
        let start = caret
        var consumed = 0
        if contains(caret), vertical != 0 {
            let direction = vertical > 0 ? 1 : -1
            while consumed < abs(vertical), stepLine(direction) {
                consumed += 1
            }
        }
        caret += horizontal
        if contains(caret), horizontal != 0 {
            preferredColumn = columnPreference(at: caret)
        }
        let consumedVertical = vertical < 0 ? -consumed : consumed
        return Move(offset: caret - start, consumedVertical: consumedVertical)
    }

    private func contains(_ index: Int) -> Bool {
        index >= 0 && index <= units.count
    }

    private mutating func stepLine(_ direction: Int) -> Bool {
        let line = hardLine(at: caret)
        let length = line.end - line.start
        let row = visualRow(column: caret - line.start, length: length)
        if direction < 0 {
            if row > 0 {
                return place(lineStart: line.start, lineLength: length, row: row - 1)
            }
            guard let previous = previousHardLine(before: line.start) else { return false }
            let previousLength = previous.end - previous.start
            let lastRow = visualRow(column: previousLength, length: previousLength)
            return place(lineStart: previous.start, lineLength: previousLength, row: lastRow)
        }
        if (row + 1) * visualLineLength < length {
            return place(lineStart: line.start, lineLength: length, row: row + 1)
        }
        guard let next = nextHardLine(after: line.end) else { return false }
        return place(lineStart: next.start, lineLength: next.end - next.start, row: 0)
    }

    private mutating func place(lineStart: Int, lineLength: Int, row: Int) -> Bool {
        let rowStart = row * visualLineLength
        guard rowStart <= lineLength else { return false }
        let room = min(visualLineLength, lineLength - rowStart)
        let next = snap(lineStart + rowStart + min(preferredColumn, room))
        guard next != caret else { return false }
        caret = next
        return true
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
        guard index > 0, index < units.count else { return index }
        let unit = units[index]
        guard unit >= Self.lowSurrogateStart, unit <= Self.lowSurrogateEnd else { return index }
        return index - 1
    }
}
