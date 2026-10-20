import UIKit

/// Keyboards only see the text around the cursor, cut off at sentence and
/// paragraph boundaries. Reading the whole field means walking the cursor
/// to the start, then to the end, collecting text along the way.
///
/// Cursor moves count UTF-16 code units, and the host applies them
/// asynchronously: the text before the cursor can update well before the
/// text after it, which can read as empty for a while in the middle of the
/// field. So a move only counts once the context shows it landed, and only
/// a move that never shows marks an edge of the field.
///
/// Between blank lines a host can show the same context at every position,
/// so a step there can pass unseen. The read then stops at the first blank
/// line, leaving what follows for a polish of its own.
@MainActor
struct DocumentReader {
    let proxy: UITextDocumentProxy
    /// How long a move may take to show before the cursor is taken to be at an edge,
    /// until moves have shown how quick this host is.
    var edgeTimeout: Duration = .seconds(1)
    /// Once moves have landed, an edge waits this many times the slowest of them,
    /// but never less than `shortestEdgeTimeout`: most hosts show a move well within
    /// 100 ms, so a full second at each end of the field was most of a polish's wait.
    var edgeTimeoutPerLanding = 4
    var shortestEdgeTimeout: Duration = .milliseconds(400)
    /// How long a move over known text may take to show before the reader gives up.
    var landingTimeout: Duration = .seconds(3)
    /// How long a step that only changed the text after the cursor may take to show before it too.
    var stepSettle: Duration = .milliseconds(300)
    private let landings = Landings()

    /// The slowest a move has taken to show in this read.
    private final class Landings {
        var slowest: Duration?
    }

    private var edgeWait: Duration {
        guard let slowest = landings.slowest else { return edgeTimeout }
        return min(max(slowest * edgeTimeoutPerLanding, shortestEdgeTimeout), edgeTimeout)
    }

    /// Returns the field's full text and leaves the cursor at its end.
    func readWholeDocument() async throws -> String {
        try await moveToStart()
        return try await readToEnd()
    }

    /// Swaps `original`, just read by `readWholeDocument`, for `replacement`,
    /// unless the cursor has since left the end of it.
    func replace(_ original: String, with replacement: String) throws {
        let before = proxy.documentContextBeforeInput ?? ""
        guard (proxy.documentContextAfterInput ?? "").isEmpty, original.hasSuffix(before) else {
            throw DocumentReaderError.textChanged
        }
        // The read ends with a step that showed nothing. After a line break
        // that can be a step between blank lines, so the cursor may be one
        // past what was read. If it isn't, the extra delete lands at the
        // start of the field, where it does nothing.
        let unseenStep = before.last?.isNewline ?? true ? 1 : 0
        for _ in 0..<(original.count + unseenStep) { proxy.deleteBackward() }
        proxy.insertText(replacement)
    }

    private func moveToStart() async throws {
        var unseenMoves = 0
        while unseenMoves < 20 {
            let before = proxy.documentContextBeforeInput ?? ""
            let moved = try await move(by: before.isEmpty ? -1 : -before.utf16.count, within: before.isEmpty ? edgeWait : stepSettle) { $0 != $1 }
            // Nothing before the cursor and nothing moving is the start. Text
            // before the cursor means it isn't: the move went among blank lines,
            // which a host can show the same context on, or hasn't shown yet.
            if moved { unseenMoves = 0 } else if before.isEmpty { return } else { unseenMoves += 1 }
        }
    }

    private func readToEnd() async throws -> String {
        var text = ""
        while true {
            let after = proxy.documentContextAfterInput ?? ""
            guard after.isEmpty else {
                // Landed once the text before the cursor ends with what was
                // just crossed, or is all of its end when the host shares less.
                let landed = try await move(by: after.utf16.count, within: landingTimeout) { old, now in
                    guard let before = now.before, !before.isEmpty, now.before != old.before else { return false }
                    return before.hasSuffix(after) || after.hasSuffix(before)
                }
                guard landed else { throw DocumentReaderError.lostCursor }
                text += after
                continue
            }
            // The end of the field, a boundary the host cuts the context at,
            // or a host that hasn't caught up. Step one character: it's the
            // last character before the cursor, unless the context restarted
            // at a new paragraph, in which case it was a line break.
            let start = context
            guard try await move(by: 1, within: edgeWait, until: Self.stepped) else { return text }
            if context.before == start.before {
                // Only the text after the cursor changed: either the host shows
                // the same line break before the cursor on both sides of the
                // step, or that's the last move catching up and the step is
                // still on its way.
                _ = try await wait(within: stepSettle) { $0.before != start.before && Self.stepped(from: start, to: $0) }
            }
            text += (proxy.documentContextBeforeInput ?? "").last.map(String.init) ?? "\n"
        }
    }

    /// Whether a one-character step forward shows: the text before the cursor
    /// gained the character crossed, or restarted at a new paragraph. Hosts
    /// also redraw the text before an unmoved cursor wider or narrower, which
    /// isn't a step. Between blank lines a host can show the same line break
    /// on both sides, so there only the text after the cursor shows the step.
    private static func stepped(from old: Context, to now: Context) -> Bool {
        let oldBefore = old.before ?? ""
        let newBefore = now.before ?? ""
        guard newBefore != oldBefore else { return now.after != old.after && (oldBefore.last?.isNewline ?? true) }
        guard let crossed = newBefore.last else { return true }
        let extended = oldBefore + String(crossed)
        return extended.hasSuffix(newBefore) || newBefore.hasSuffix(extended)
    }

    private struct Context: Equatable {
        let before: String?
        let after: String?
    }

    private var context: Context {
        Context(before: proxy.documentContextBeforeInput, after: proxy.documentContextAfterInput)
    }

    /// Moves the cursor and waits until `landed(old, new)` holds for the
    /// context around it, reporting whether it did in time.
    private func move(by offset: Int, within timeout: Duration, until landed: (Context, Context) -> Bool) async throws -> Bool {
        try Task.checkCancellation()
        let start = context
        let began = ContinuousClock.now
        proxy.adjustTextPosition(byCharacterOffset: offset)
        guard try await wait(within: timeout, until: { landed(start, $0) }) else { return false }
        let took = ContinuousClock.now - began
        landings.slowest = max(landings.slowest ?? took, took)
        return true
    }

    private func wait(within timeout: Duration, until done: (Context) -> Bool) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            if done(context) { return true }
        }
        return false
    }
}

enum DocumentReaderError: LocalizedError {
    case lostCursor
    case textChanged

    var errorDescription: String? {
        switch self {
        case .lostCursor: "Couldn't read the whole text. Select it and polish again."
        case .textChanged: "The text changed while polishing. Polish again."
        }
    }
}
