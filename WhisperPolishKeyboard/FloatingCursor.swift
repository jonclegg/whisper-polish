import UIKit

/// The known text as the trackpad panel shows it: the body font wrapped at the
/// panel's width. The panel draws from this same layout, so the line the
/// cursor steers to is the line on screen. Indexes are UTF-16 offsets, the
/// unit `adjustTextPosition(byCharacterOffset:)` counts in.
@MainActor
final class TrackpadLayout {
    static let font = UIFont.preferredFont(forTextStyle: .body)

    let length: Int
    let width: CGFloat
    /// Layout managers don't keep their text storage alive; this does.
    private let storage: NSTextStorage
    private let layoutManager = NSLayoutManager()
    private let container: NSTextContainer
    /// Each insertion point's line and how far along it the cursor shows. A
    /// wrapped line's last offset shows at the start of the next line.
    private var lines: [Int] = []
    private var xs: [CGFloat] = []
    private var lineTops: [CGFloat] = []
    private(set) var lineCount = 0
    private(set) var height: CGFloat = 0

    init(text: String, width: CGFloat) {
        let units = text as NSString
        length = units.length
        self.width = width
        storage = NSTextStorage(string: text, attributes: [.font: Self.font, .foregroundColor: UIColor.label])
        container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        layoutManager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)) { rect, _, _, glyphs, _ in
            let characters = self.layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            for index in characters.location..<NSMaxRange(characters) {
                self.lines.append(self.lineCount)
                self.xs.append(rect.minX + self.layoutManager.location(forGlyphAt: self.layoutManager.glyphIndexForCharacter(at: index)).x)
            }
            self.lineTops.append(rect.minY)
            self.lineCount += 1
            self.height = rect.maxY
        }
        // The end of the text: after a trailing line break it's on a line of its own.
        if length == 0 {
            lines.append(0)
            xs.append(0)
            lineTops.append(0)
            lineCount = 1
            height = Self.font.lineHeight
        } else if units.character(at: length - 1) == 10 {
            lines.append(lineCount)
            xs.append(0)
            lineTops.append(height)
            lineCount += 1
            height += Self.font.lineHeight
        } else {
            lines.append(lineCount - 1)
            xs.append(layoutManager.boundingRect(forGlyphRange: NSRange(location: layoutManager.numberOfGlyphs - 1, length: 1), in: container).maxX)
        }
    }

    func line(of index: Int) -> Int { lines[index] }

    /// The insertion points on a line.
    func indexes(onLine line: Int) -> ClosedRange<Int> {
        let first = lines.firstIndex(of: line)!
        let last = lines.lastIndex(of: line)!
        return first...last
    }

    func caretX(at index: Int) -> CGFloat { xs[index] }

    func caretRect(at index: Int) -> CGRect {
        CGRect(x: xs[index], y: lineTops[lines[index]], width: 2, height: Self.font.lineHeight)
    }

    func draw(at origin: CGPoint) {
        layoutManager.drawGlyphs(forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs), at: origin)
    }
}

/// Holding space steers an invisible cursor like a mouse: it starts on the
/// real cursor and travels with the finger, and the real cursor goes to the
/// character under it. Keyboards never learn how the app lays out its text, so
/// the keys give way to a panel showing the known text in the keyboard's own
/// layout, and the cursor moves through that: a line up is the line above in
/// the panel, wherever the app happens to wrap.
///
/// Hosts only share the sentence or paragraph around the cursor, so the panel
/// starts with that. Reading past the known text means moving the host's
/// cursor to its edge, so it waits until the invisible cursor goes past that edge.
@MainActor
final class FloatingCursor {
    /// The cursor travels farther than the finger sideways so one drag covers
    /// a line, and as far as the finger up and down so each line takes a full
    /// line's travel.
    private static let gain = CGVector(dx: 1.5, dy: 1)
    /// How far past a line's edge, in lines, the finger goes before the cursor
    /// leaves it, so a finger resting near the edge doesn't flip between lines.
    private static let lineMargin: CGFloat = 0.3
    /// How long the host gets to show a move within the known text.
    private static let moveTimeout: TimeInterval = 0.3
    /// A step past the known text the host doesn't show by then means the cursor is at the document's edge.
    private static let stepTimeout: TimeInterval = 0.12
    /// The host can report a move in more than one update; it has caught up once its context holds still this long.
    private static let hostQuiet: TimeInterval = 0.02

    private let proxy: UITextDocumentProxy
    private let width: CGFloat
    private let lineHeight = TrackpadLayout.font.lineHeight
    /// Called with the layout and the cursor whenever either changes, to redraw the panel.
    private let onChange: (TrackpadLayout, Int) -> Void
    private(set) var text: String
    private(set) var layout: TrackpadLayout
    /// Where the host's cursor is in `text`.
    private(set) var cursor: Int
    /// Where the drag started in `text`; sideways, the invisible cursor is measured from it.
    private var start: Int
    /// The character the invisible cursor last reached a line at; up and down,
    /// it's measured from the middle of this character's line.
    private var origin: Int
    /// The finger's travel scaled by `gain`: sideways since the drag started,
    /// up and down since the invisible cursor reached the origin's line.
    private var travel = CGVector.zero
    private var reachedStart = false
    private var reachedEnd = false
    /// Whether the known text is known to start or end a paragraph, so its
    /// first or last line is a real line and sideways moves stop there.
    private var startsParagraph = false
    private var endsParagraph = false
    private var isReading = false
    private var isEnded = false

    init(proxy: UITextDocumentProxy, width: CGFloat, onChange: @escaping (TrackpadLayout, Int) -> Void) {
        self.proxy = proxy
        self.width = width
        self.onChange = onChange
        let before = proxy.documentContextBeforeInput ?? ""
        let after = proxy.documentContextAfterInput ?? ""
        text = before + after
        layout = TrackpadLayout(text: text, width: width)
        cursor = before.utf16.count
        start = cursor
        origin = cursor
        // Hosts share the text back to the start of the paragraph or the sentence before, so nothing before the cursor means it starts a paragraph.
        startsParagraph = before.isEmpty
        onChange(layout, cursor)
    }

    func move(by delta: CGVector) {
        travel.dx += delta.dx * Self.gain.dx
        travel.dy += delta.dy * Self.gain.dy
        guard !isReading else { return }
        follow()
    }

    /// A read in progress still finishes and puts the cursor under the finger.
    func end() {
        isEnded = true
    }

    private func follow() {
        let threshold = lineHeight * (0.5 + Self.lineMargin)
        while abs(travel.dy) > threshold {
            let up = travel.dy < 0
            let line = layout.line(of: origin)
            if up ? line == 0 : line == layout.lineCount - 1 {
                guard up ? reachedStart || isEnded : reachedEnd || isEnded else { return read(up: up, crossingLine: up ? startsParagraph : endsParagraph) }
                // Like a pointer at the screen's edge, the invisible cursor stops there so turning back answers at once.
                travel.dy = up ? -threshold : threshold
                break
            }
            origin = nearestCharacter(onLine: line + (up ? -1 : 1))
            travel.dy += up ? lineHeight : -lineHeight
        }
        // Sideways past the known text's first or last character, the text goes on unless that's a paragraph's edge.
        let line = layout.line(of: origin)
        if line == 0, x < 0 {
            guard startsParagraph || isEnded else { return read(up: true, crossingLine: false) }
        }
        if line == layout.lineCount - 1, x > layout.caretX(at: layout.length) {
            guard endsParagraph || isEnded else { return read(up: false, crossingLine: false) }
            travel.dx -= x - layout.caretX(at: layout.length)
        }
        // Like a pointer at the screen's edge, the invisible cursor stops at the panel's sides so turning back answers at once.
        travel.dx = min(max(travel.dx, -layout.caretX(at: start)), width - layout.caretX(at: start))
        let target = nearestCharacter(onLine: line)
        if target != cursor {
            proxy.adjustTextPosition(byCharacterOffset: target - cursor)
            cursor = target
        }
        onChange(layout, cursor)
    }

    /// Where the invisible cursor is sideways.
    private var x: CGFloat {
        layout.caretX(at: start) + travel.dx
    }

    /// The character on `line` nearest the invisible cursor sideways.
    private func nearestCharacter(onLine line: Int) -> Int {
        let units = text as NSString
        let goal = min(max(x, 0), width)
        return layout.indexes(onLine: line)
            .filter { $0 == units.length || units.rangeOfComposedCharacterSequence(at: $0).location == $0 }
            .min { abs(layout.caretX(at: $0) - goal) < abs(layout.caretX(at: $1) - goal) }!
    }

    // MARK: - Reading

    private func read(up: Bool, crossingLine: Bool) {
        isReading = true
        Task {
            if up { await readUp(crossingLine: crossingLine) } else { await readDown(crossingLine: crossingLine) }
            layout = TrackpadLayout(text: text, width: width)
            isReading = false
            follow()
        }
    }

    /// Reads the text before the known text and puts it in front. At a
    /// paragraph's start that means stepping over its line break, which only
    /// happens when the finger has gone up a line.
    private func readUp(crossingLine: Bool) async {
        guard await moveHost(to: 0) else {
            reachedStart = true
            startsParagraph = true
            return
        }
        var before = proxy.documentContextBeforeInput ?? ""
        var joint = ""
        if before.isEmpty {
            // The host's context stopped at a sentence or paragraph boundary, so step over it.
            guard crossingLine else {
                startsParagraph = true
                return
            }
            let known = text
            let stepped = await stepHost(by: -1) { _, after in
                let rest = after.isEmpty ? "" : (after as NSString).substring(from: 1)
                return known.hasPrefix(rest) || rest.hasPrefix(known)
            }
            guard stepped else {
                reachedStart = true
                startsParagraph = true
                return
            }
            before = proxy.documentContextBeforeInput ?? ""
            joint = Self.steppedCharacter(proxy.documentContextAfterInput?.utf16.first)
        }
        text = before + joint + text
        cursor = before.utf16.count
        start += before.utf16.count + joint.utf16.count
        origin += before.utf16.count + joint.utf16.count
        startsParagraph = false
    }

    /// Reads the text after the known text and puts it behind.
    private func readDown(crossingLine: Bool) async {
        let length = text.utf16.count
        guard await moveHost(to: length) else {
            reachedEnd = true
            endsParagraph = true
            return
        }
        var after = proxy.documentContextAfterInput ?? ""
        var joint = ""
        if after.isEmpty {
            guard crossingLine else {
                endsParagraph = true
                return
            }
            let known = text
            let stepped = await stepHost(by: 1) { before, _ in
                let rest = before.isEmpty ? "" : (before as NSString).substring(to: before.utf16.count - 1)
                return known.hasSuffix(rest) || rest.hasSuffix(known)
            }
            guard stepped else {
                reachedEnd = true
                endsParagraph = true
                return
            }
            after = proxy.documentContextAfterInput ?? ""
            joint = Self.steppedCharacter(proxy.documentContextBeforeInput?.utf16.last)
        }
        text = text + joint + after
        cursor = length + joint.utf16.count
        endsParagraph = false
    }

    /// The character a one-unit step crossed, as the context on its far side shows it.
    /// Hosts leave a line break out of the context, so a missing one was a line break.
    private static func steppedCharacter(_ unit: UTF16.CodeUnit?) -> String {
        unit.map { String(utf16CodeUnits: [$0], count: 1) } ?? "\n"
    }

    private var hostContext: (before: String, after: String) {
        (proxy.documentContextBeforeInput ?? "", proxy.documentContextAfterInput ?? "")
    }

    /// Moves the host's cursor within the known text and waits until its
    /// context shows it there.
    private func moveHost(to index: Int) async -> Bool {
        let start = hostContext
        let moved = index != cursor
        if moved {
            proxy.adjustTextPosition(byCharacterOffset: index - cursor)
            cursor = index
        }
        let known = text as NSString
        let knownBefore = known.substring(to: index)
        let knownAfter = known.substring(from: index)
        return await waitForHost(timeout: Self.moveTimeout) {
            let (before, after) = self.hostContext
            return (!moved || (before, after) != start)
                && (knownBefore.hasSuffix(before) || before.hasSuffix(knownBefore))
                && (knownAfter.hasPrefix(after) || after.hasPrefix(knownAfter))
        }
    }

    /// Steps the host's cursor one unit past the known text and waits until its
    /// context is the known text plus the crossed character, reporting whether it moved at all.
    private func stepHost(by offset: Int, until joinsKnownText: (String, String) -> Bool) async -> Bool {
        let start = hostContext
        proxy.adjustTextPosition(byCharacterOffset: offset)
        return await waitForHost(timeout: Self.stepTimeout) {
            let context = self.hostContext
            return context != start && joinsKnownText(context.before, context.after)
        }
    }

    private func waitForHost(timeout: TimeInterval, until isDone: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var context = hostContext
        var lastChange = Date()
        while true {
            let now = Date()
            if hostContext != context {
                context = hostContext
                lastChange = now
            }
            if now.timeIntervalSince(lastChange) >= Self.hostQuiet && isDone() { return true }
            guard now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
