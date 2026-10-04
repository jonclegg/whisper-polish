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
/// keyboard's trackpad. Hosts only share text up to a sentence or paragraph
/// boundary, so pushing past the known text waits for the host to catch up,
/// then reads further.
@MainActor
final class FloatingCursor {
    /// How long after the last move the host's reported text can be trusted again.
    private static let settleDelay: TimeInterval = 0.12

    private let proxy: UITextDocumentProxy
    private let screenWidth: CGFloat
    private var layout: EstimatedTextLayout
    private var cursor = 0
    private var point = CGPoint.zero
    private var lastMove = Date.distantPast
    /// Set after stepping blindly over a boundary, until the text is read again.
    private var isStale = false

    init(proxy: UITextDocumentProxy, screenWidth: CGFloat) {
        self.proxy = proxy
        self.screenWidth = screenWidth
        layout = EstimatedTextLayout(text: "", screenWidth: screenWidth)
        reload()
    }

    func move(by delta: CGVector) {
        point.x += delta.dx
        point.y += delta.dy
        let now = Date()
        let isSettled = now.timeIntervalSince(lastMove) > Self.settleDelay
        if isStale {
            guard isSettled else { return }
            reload()
        }
        let bounds = layout.bounds
        let target = layout.index(nearest: point)
        let pushesStart = target == 0 && (point.y < bounds.minY || point.x < bounds.minX)
        let pushesEnd = target == layout.length && (point.y > bounds.maxY || point.x > bounds.maxX)
        point.x = min(max(point.x, bounds.minX), bounds.maxX)
        point.y = min(max(point.y, bounds.minY), bounds.maxY)
        if target != cursor {
            proxy.adjustTextPosition(byCharacterOffset: target - cursor)
            cursor = target
            lastMove = now
            return
        }
        guard (pushesStart || pushesEnd) && isSettled else { return }
        reload()
        let atEdge = pushesStart ? cursor == 0 : cursor == layout.length
        guard atEdge else { return }
        // The host stops its text at a paragraph break; stepping over it reveals the next paragraph.
        proxy.adjustTextPosition(byCharacterOffset: pushesStart ? -1 : 1)
        lastMove = now
        isStale = true
    }

    private func reload() {
        let before = proxy.documentContextBeforeInput ?? ""
        let after = proxy.documentContextAfterInput ?? ""
        layout = EstimatedTextLayout(text: before + after, screenWidth: screenWidth)
        cursor = (before as NSString).length
        point = layout.caretPoint(at: cursor)
        isStale = false
    }
}
