import UIKit

/// One way the host might lay out the known text: the body font wrapped at a
/// given width, with the first line starting `indent` in, since the known
/// text can begin partway along a line. Indexes are UTF-16 offsets, the unit
/// `adjustTextPosition(byCharacterOffset:)` counts in.
@MainActor
final class EstimatedTextLayout {
    let length: Int
    private let indent: CGFloat
    private let text: NSString
    private let storage: NSTextStorage
    private let layoutManager = NSLayoutManager()
    private let container: NSTextContainer
    /// Each visual line, plus an empty last line after a trailing line break.
    private var lines: [(range: NSRange, rect: CGRect)] = []

    init(text: String, width: CGFloat, indent: CGFloat) {
        self.text = text as NSString
        self.indent = indent
        length = self.text.length
        let font = UIFont.preferredFont(forTextStyle: .body)
        storage = NSTextStorage(string: text, attributes: [.font: font])
        let firstParagraph = self.text.paragraphRange(for: NSRange(location: 0, length: 0))
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = indent
        storage.addAttribute(.paragraphStyle, value: style, range: firstParagraph)
        container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        layoutManager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)) { rect, _, _, glyphs, _ in
            self.lines.append((self.layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil), rect))
        }
        let extra = layoutManager.extraLineFragmentRect
        if extra.height > 0 || lines.isEmpty {
            let rect = extra.height > 0 ? extra : CGRect(x: 0, y: 0, width: width, height: font.lineHeight)
            lines.append((NSRange(location: length, length: 0), rect))
        }
    }

    var lineCount: Int { lines.count }

    var width: CGFloat { container.size.width }

    func line(of index: Int) -> Int {
        // The last line whose range starts at or before the index; a wrapped line's end belongs to the next line.
        var low = 0
        var high = lines.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lines[middle].range.location <= index { low = middle } else { high = middle - 1 }
        }
        return low
    }

    func caretX(at index: Int) -> CGFloat {
        let line = lines[line(of: index)]
        let start = line.range.location
        guard index > start else { return start == 0 ? indent : 0 }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: start, length: index - start), actualCharacterRange: nil)
        return layoutManager.boundingRect(forGlyphRange: glyphs, in: container).maxX
    }

    /// The insertion point on `line` nearest `x`.
    func index(onLine lineIndex: Int, nearestX x: CGFloat) -> Int {
        let line = lines[lineIndex]
        var fraction: CGFloat = 0
        let hit = layoutManager.characterIndex(for: CGPoint(x: x, y: line.rect.midY), in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
        let index = fraction > 0.5 && hit < length ? NSMaxRange(text.rangeOfComposedCharacterSequence(at: hit)) : hit
        // A wrapped line's last offset belongs to the next line, so stop before its final character.
        let lineEnd = lineIndex == lines.count - 1 || line.range.length == 0
            ? NSMaxRange(line.range)
            : text.rangeOfComposedCharacterSequence(at: NSMaxRange(line.range) - 1).location
        return min(max(index, line.range.location), lineEnd)
    }
}

/// Holding space steers an invisible cursor like a mouse: it starts on the
/// real cursor and travels with the finger, and the real cursor goes to the
/// character under it. Keyboards never learn how the app lays out its text,
/// and hosts only share the sentence or paragraph around the cursor, so where
/// the lines wrap is a guess. Rather than trust one guess, the cursor follows
/// a range of them, fields from a chat box's width to the screen's with the
/// known text starting anywhere along its first line, and goes to the
/// character most of them put on the invisible cursor's line. A single guess
/// is wrong often enough that a small move can land two lines away.
///
/// Reading past the known text means moving the host's cursor to its edge, so
/// it waits until the invisible cursor goes past that edge in most guesses.
@MainActor
final class FloatingCursor {
    /// The cursor travels farther than the finger sideways so one drag covers
    /// a line, and as far as the finger up and down so each line takes a full
    /// line's travel.
    private static let gain = CGVector(dx: 1.5, dy: 1)
    /// How far past a line's edge, in lines, the finger goes before the cursor
    /// leaves it, so a finger resting near the edge doesn't flip between lines.
    private static let lineMargin: CGFloat = 0.3
    /// How far in from each screen edge the host's text might sit: a full-width
    /// editor like Notes at the low end, a chat box beside its buttons like
    /// Messages at the high end.
    private static let fieldInsets: [CGFloat] = [21, 30, 40, 50, 60]
    /// Where along its first line the known text might start, as fractions of the line.
    private static let indents: [CGFloat] = [0, 0.25, 0.5, 0.75]
    /// How long the host gets to show a move within the known text.
    private static let moveTimeout: TimeInterval = 0.3
    /// A step past the known text the host doesn't show by then means the cursor is at the document's edge.
    private static let stepTimeout: TimeInterval = 0.12
    /// The host can report a move in more than one update; it has caught up once its context holds still this long.
    private static let hostQuiet: TimeInterval = 0.02

    private let proxy: UITextDocumentProxy
    private let screenWidth: CGFloat
    private let lineHeight = UIFont.preferredFont(forTextStyle: .body).lineHeight
    private var text: String
    private var layouts: [EstimatedTextLayout] = []
    /// Where the host's cursor is in `text`.
    private var cursor: Int
    /// The character the invisible cursor last reached a line at, straight
    /// above or below where it was; it's measured from here.
    private var origin: Int
    /// The finger's travel since the invisible cursor reached the origin, scaled
    /// by `gain`. Up and down, it's from the middle of the origin's line.
    private var travel = CGVector.zero
    private var reachedStart = false
    private var reachedEnd = false
    /// Whether the known text is known to start or end a paragraph, so its
    /// first or last line is a real line and sideways moves stop there.
    private var startsParagraph = false
    private var endsParagraph = false
    private var isReading = false
    private var isEnded = false

    init(proxy: UITextDocumentProxy, screenWidth: CGFloat) {
        self.proxy = proxy
        self.screenWidth = screenWidth
        let before = proxy.documentContextBeforeInput ?? ""
        let after = proxy.documentContextAfterInput ?? ""
        text = before + after
        cursor = before.utf16.count
        origin = cursor
        // Hosts share the text back to the start of the paragraph or the sentence before, so nothing before the cursor means it starts a paragraph.
        startsParagraph = before.isEmpty
        layOut()
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

    private func layOut() {
        let indents = startsParagraph ? [0] : Self.indents
        layouts = Self.fieldInsets.flatMap { inset in
            indents.map { EstimatedTextLayout(text: text, width: screenWidth - 2 * inset, indent: $0 * (screenWidth - 2 * inset)) }
        }
    }

    private func follow() {
        let threshold = lineHeight * (0.5 + Self.lineMargin)
        let most = layouts.count / 2 + 1
        while abs(travel.dy) > threshold {
            let up = travel.dy < 0
            let atEdge = layouts.filter { up ? $0.line(of: origin) == 0 : $0.line(of: origin) == $0.lineCount - 1 }.count
            if atEdge >= most {
                guard up ? reachedStart || isEnded : reachedEnd || isEnded else { return read(up: up, crossingLine: up ? startsParagraph : endsParagraph) }
                // Like a pointer at the screen's edge, the invisible cursor stops there so turning back answers at once.
                travel.dy = up ? -threshold : threshold
                break
            }
            origin = character(onNextLine: up)
            travel.dy += up ? lineHeight : -lineHeight
        }
        travel.dx = min(max(travel.dx, -layouts.map { $0.caretX(at: origin) }.max()!), layouts.map { $0.width - $0.caretX(at: origin) }.max()!)
        // Sideways the invisible cursor goes with the finger; the guesses agree on
        // how far along a line that is and only differ on where lines end.
        var underFinger: [Int] = []
        var before: [CGFloat] = []
        var after: [CGFloat] = []
        for layout in layouts {
            let line = layout.line(of: origin)
            let x = layout.caretX(at: origin) + travel.dx
            underFinger.append(layout.index(onLine: line, nearestX: x))
            if line == 0, x < layout.caretX(at: 0) { before.append(layout.caretX(at: 0) - x) }
            if line == layout.lineCount - 1, x > layout.caretX(at: layout.length) { after.append(x - layout.caretX(at: layout.length)) }
        }
        if before.count >= most {
            guard startsParagraph || isEnded else { return read(up: true, crossingLine: false) }
            travel.dx += median(before)
        }
        if after.count >= most {
            guard endsParagraph || isEnded else { return read(up: false, crossingLine: false) }
            travel.dx -= median(after)
        }
        let units = text as NSString
        let middle = underFinger.sorted()[underFinger.count / 2]
        let target = middle < units.length ? units.rangeOfComposedCharacterSequence(at: middle).location : middle
        if target != cursor {
            proxy.adjustTextPosition(byCharacterOffset: target - cursor)
            cursor = target
        }
    }

    /// The character straight above or below the origin on the next line: the
    /// one the most guesses put on that line, nearest the middle guess.
    /// Trusting any one guess, or even the middle one, lands two lines away far
    /// more often.
    private func character(onNextLine up: Bool) -> Int {
        let step = up ? -1 : 1
        var straight: [Int] = []
        for layout in layouts {
            let line = layout.line(of: origin) + step
            guard line >= 0 && line < layout.lineCount else { continue }
            straight.append(layout.index(onLine: line, nearestX: layout.caretX(at: origin)))
        }
        straight.sort()
        let median = straight[straight.count / 2]
        var best = median
        var bestVotes = -1
        for candidate in straight[0]...straight[straight.count - 1] {
            let votes = layouts.reduce(0) { $0 + ($1.line(of: candidate) == $1.line(of: origin) + step ? 1 : 0) }
            if votes > bestVotes || (votes == bestVotes && abs(candidate - median) < abs(best - median)) {
                best = candidate
                bestVotes = votes
            }
        }
        return best
    }

    private func median(_ values: [CGFloat]) -> CGFloat {
        values.sorted()[values.count / 2]
    }

    // MARK: - Reading

    private func read(up: Bool, crossingLine: Bool) {
        isReading = true
        Task {
            if up { await readUp(crossingLine: crossingLine) } else { await readDown(crossingLine: crossingLine) }
            layOut()
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
