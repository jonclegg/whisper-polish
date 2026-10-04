import UIKit

/// Keyboards never learn how the app lays out its text, so the floating cursor
/// steers through an estimate: the known text around the cursor wrapped the
/// way a full-width field in the body font would wrap it. Indexes are UTF-16
/// offsets, the unit `adjustTextPosition(byCharacterOffset:)` counts in.
@MainActor
final class EstimatedTextLayout {
    private static let fieldInset: CGFloat = 16

    let length: Int
    private let text: NSString
    private let storage: NSTextStorage
    private let layoutManager = NSLayoutManager()
    private let container: NSTextContainer
    /// Each visual line, plus an empty last line after a trailing line break.
    private var lines: [(range: NSRange, rect: CGRect)] = []

    init(text: String, screenWidth: CGFloat) {
        self.text = text as NSString
        length = self.text.length
        let font = UIFont.preferredFont(forTextStyle: .body)
        storage = NSTextStorage(string: text, attributes: [.font: font])
        container = NSTextContainer(size: CGSize(width: screenWidth - 2 * Self.fieldInset, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        layoutManager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)) { rect, _, _, glyphs, _ in
            self.lines.append((self.layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil), rect))
        }
        let extra = layoutManager.extraLineFragmentRect
        if extra.height > 0 || lines.isEmpty {
            let rect = extra.height > 0 ? extra : CGRect(x: 0, y: 0, width: container.size.width, height: font.lineHeight)
            lines.append((NSRange(location: length, length: 0), rect))
        }
    }

    var lineHeight: CGFloat { lines[0].rect.height }

    var bounds: CGRect {
        CGRect(x: 0, y: lines[0].rect.minY, width: container.size.width, height: lines[lines.count - 1].rect.maxY - lines[0].rect.minY)
    }

    func caretPoint(at index: Int) -> CGPoint {
        let line = lines.first { NSLocationInRange(index, $0.range) } ?? lines[lines.count - 1]
        let start = line.range.location
        guard index > start else { return CGPoint(x: 0, y: line.rect.midY) }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: start, length: index - start), actualCharacterRange: nil)
        return CGPoint(x: layoutManager.boundingRect(forGlyphRange: glyphs, in: container).maxX, y: line.rect.midY)
    }

    /// The insertion point nearest `point`, kept on the line under it.
    func index(nearest point: CGPoint) -> Int {
        let lineIndex = lines.firstIndex { point.y < $0.rect.maxY } ?? lines.count - 1
        let line = lines[lineIndex]
        var fraction: CGFloat = 0
        let hit = layoutManager.characterIndex(for: CGPoint(x: point.x, y: line.rect.midY), in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
        let index = fraction > 0.5 && hit < length ? NSMaxRange(text.rangeOfComposedCharacterSequence(at: hit)) : hit
        // A wrapped line's last offset belongs to the next line, so stop before its final character.
        let lineEnd = lineIndex == lines.count - 1 || line.range.length == 0
            ? NSMaxRange(line.range)
            : text.rangeOfComposedCharacterSequence(at: NSMaxRange(line.range) - 1).location
        return min(max(index, line.range.location), lineEnd)
    }
}

/// Holding space steers an invisible cursor through the estimated layout and
/// the real cursor jumps to the insertion point nearest it, like the system
/// keyboard's trackpad. Hosts only share the sentence or paragraph around the
/// cursor, so as the finger nears the edge of the known text the cursor
/// briefly visits that edge to read the next piece, which joins the layout.
@MainActor
final class FloatingCursor {
    /// Rows read above the cursor before it starts following the finger, about
    /// a drag from the space bar to the top of the keyboard. Reading moves the
    /// host's cursor, so it's done up front while the keys fade instead of mid-drag.
    private static let prefetchRows: CGFloat = 15
    /// Rows of known text kept ahead of the finger once it's moving.
    private static let lookahead: CGFloat = 5
    /// A step the host hasn't answered by then means the cursor is at the document's edge.
    private static let hostTimeout: TimeInterval = 0.15

    private let proxy: UITextDocumentProxy
    private let screenWidth: CGFloat
    private var text: String
    private var layout: EstimatedTextLayout
    /// Where the host's cursor is in `text`.
    private var cursor: Int
    private var point: CGPoint
    private var reachedStart = false
    private var reachedEnd = false
    private var isReading = false
    private var isEnded = false
    private var direction = CGVector.zero

    init(proxy: UITextDocumentProxy, screenWidth: CGFloat) {
        self.proxy = proxy
        self.screenWidth = screenWidth
        let before = proxy.documentContextBeforeInput ?? ""
        text = before + (proxy.documentContextAfterInput ?? "")
        cursor = before.utf16.count
        layout = EstimatedTextLayout(text: text, screenWidth: screenWidth)
        point = layout.caretPoint(at: cursor)
        prefetch()
    }

    func move(by delta: CGVector) {
        point.x += delta.dx
        point.y += delta.dy
        direction = delta
        guard !isReading else { return }
        follow()
    }

    /// A read in progress still finishes and puts the cursor back under the finger.
    func end() {
        isEnded = true
    }

    private func follow() {
        let bounds = layout.bounds
        if reachedStart { point.y = max(point.y, bounds.minY) }
        if reachedEnd { point.y = min(point.y, bounds.maxY) }
        let target = layout.index(nearest: point)
        let maxX = reachedEnd && target == layout.length ? layout.caretPoint(at: target).x : bounds.maxX
        point.x = min(max(point.x, bounds.minX), maxX)
        if target != cursor {
            proxy.adjustTextPosition(byCharacterOffset: target - cursor)
            cursor = target
        }
        readAheadIfNeeded()
    }

    private var rowsAbove: CGFloat { (point.y - layout.bounds.minY) / layout.lineHeight }
    private var rowsBelow: CGFloat { (layout.bounds.maxY - point.y) / layout.lineHeight }

    private func prefetch() {
        isReading = true
        Task {
            while !reachedStart && rowsAbove < Self.prefetchRows { await readUp() }
            isReading = false
            follow()
        }
    }

    private func readAheadIfNeeded() {
        guard !isEnded else { return }
        let up = !reachedStart && rowsAbove < Self.lookahead && (direction.dy < 0 || direction.dx < 0)
        let down = !reachedEnd && rowsBelow < Self.lookahead && (direction.dy > 0 || direction.dx > 0)
        guard up || down else { return }
        isReading = true
        Task {
            if up { await readUp() } else { await readDown() }
            isReading = false
            follow()
        }
    }

    /// Reads the text before the known text and puts it in front.
    private func readUp() async {
        let offset = point - layout.caretPoint(at: cursor)
        let target = cursor
        await moveHost(by: -cursor)
        cursor = 0
        var before = proxy.documentContextBeforeInput ?? ""
        var joint = ""
        if before.isEmpty {
            // Hosts stop the context at a line break, so step over it.
            guard await moveHost(by: -1) else {
                reachedStart = true
                return
            }
            before = proxy.documentContextBeforeInput ?? ""
            joint = "\n"
        }
        text = before + joint + text
        cursor = before.utf16.count
        layout = EstimatedTextLayout(text: text, screenWidth: screenWidth)
        point = layout.caretPoint(at: target + cursor + joint.utf16.count) + offset
    }

    /// Reads the text after the known text and puts it behind.
    private func readDown() async {
        let offset = point - layout.caretPoint(at: cursor)
        let target = cursor
        let length = text.utf16.count
        await moveHost(by: length - cursor)
        cursor = length
        var after = proxy.documentContextAfterInput ?? ""
        var joint = ""
        if after.isEmpty {
            guard await moveHost(by: 1) else {
                reachedEnd = true
                return
            }
            after = proxy.documentContextAfterInput ?? ""
            joint = "\n"
        }
        text = text + joint + after
        cursor = length + joint.utf16.count
        layout = EstimatedTextLayout(text: text, screenWidth: screenWidth)
        point = layout.caretPoint(at: target) + offset
    }

    /// Moves the host's cursor and waits until its context reflects the move,
    /// reporting whether it moved at all.
    @discardableResult
    private func moveHost(by offset: Int) async -> Bool {
        guard offset != 0 else { return true }
        let before = proxy.documentContextBeforeInput
        let after = proxy.documentContextAfterInput
        proxy.adjustTextPosition(byCharacterOffset: offset)
        let deadline = Date().addingTimeInterval(Self.hostTimeout)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
            if proxy.documentContextBeforeInput != before || proxy.documentContextAfterInput != after { return true }
        }
        return false
    }
}

private extension CGPoint {
    static func - (lhs: CGPoint, rhs: CGPoint) -> CGVector { CGVector(dx: lhs.x - rhs.x, dy: lhs.y - rhs.y) }
    static func + (lhs: CGPoint, rhs: CGVector) -> CGPoint { CGPoint(x: lhs.x + rhs.dx, y: lhs.y + rhs.dy) }
}
