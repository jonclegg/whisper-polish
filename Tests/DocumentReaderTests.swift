import UIKit
import XCTest

/// A text field as a keyboard sees it, with the lag a real host has: cursor
/// moves count UTF-16 code units and land late, the text before the cursor
/// updates first, and the text after it reads as nothing until it catches up.
/// Only the sentence around the cursor is shared, as UITextView does.
@MainActor
private final class LaggingHost: NSObject, UITextDocumentProxy {
    private let text: NSMutableString
    private var cursor: Int
    private var reportedBefore: Int
    private var reportedAfter: Int?
    private let moveLatency: Duration
    private let afterLag: Duration
    private var queue: Task<Void, Never>?

    init(text: String, moveLatency: Duration, afterLag: Duration) {
        self.text = NSMutableString(string: text)
        cursor = self.text.length
        reportedBefore = cursor
        reportedAfter = cursor
        self.moveLatency = moveLatency
        self.afterLag = afterLag
    }

    var document: String { text as String }

    /// Waits for every move and edit handed to the host so far.
    func settle() async {
        await queue?.value
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        queue = Task { [previous = queue] in
            await previous?.value
            await work()
        }
    }

    private func isSentenceStart(_ index: Int) -> Bool {
        guard index > 0 else { return true }
        if text.character(at: index - 1) == 10 { return true }
        guard index > 1, text.character(at: index - 1) == 32 else { return false }
        return [46, 33, 63].contains(text.character(at: index - 2))
    }

    var documentContextBeforeInput: String? {
        guard reportedBefore > 0 else { return nil }
        // Just the line break on a new line, so stepping between blank lines
        // only shows in the text after the cursor.
        if text.character(at: reportedBefore - 1) == 10 { return "\n" }
        var start = reportedBefore - 1
        while !isSentenceStart(start) { start -= 1 }
        return text.substring(with: NSRange(location: start, length: reportedBefore - start))
    }

    var documentContextAfterInput: String? {
        guard let reportedAfter else { return nil }
        var end = reportedAfter
        while end < text.length, text.character(at: end) != 10, !(end > reportedAfter && isSentenceStart(end)) { end += 1 }
        return end > reportedAfter ? text.substring(with: NSRange(location: reportedAfter, length: end - reportedAfter)) : nil
    }

    func adjustTextPosition(byCharacterOffset offset: Int) {
        enqueue { [self] in
            try? await Task.sleep(for: moveLatency)
            let moved = min(max(cursor + offset, 0), text.length)
            // A move past either edge changes nothing the keyboard can see.
            guard moved != cursor else { return }
            cursor = moved
            reportedBefore = cursor
            reportedAfter = nil
            let landed = cursor
            Task { [self] in
                try? await Task.sleep(for: afterLag)
                if cursor == landed { reportedAfter = cursor }
            }
        }
    }

    func deleteBackward() {
        enqueue { [self] in
            guard cursor > 0 else { return }
            let range = text.rangeOfComposedCharacterSequence(at: cursor - 1)
            text.deleteCharacters(in: range)
            cursor = range.location
            reportedBefore = cursor
            reportedAfter = cursor
        }
    }

    func insertText(_ inserted: String) {
        enqueue { [self] in
            text.insert(inserted, at: cursor)
            cursor += (inserted as NSString).length
            reportedBefore = cursor
            reportedAfter = cursor
        }
    }

    var selectedText: String? { nil }
    var documentInputMode: UITextInputMode? { nil }
    var documentIdentifier: UUID { UUID() }
    var hasText: Bool { text.length > 0 }
    func setMarkedText(_ markedText: String, selectedRange: NSRange) {}
    func unmarkText() {}
}

@MainActor
final class DocumentReaderTests: XCTestCase {
    private static let prose = """
    The meeting ran long today. We talked about the budget and nobody agreed on anything. Sarah wants to push the launch to March.

    Next week we will try again. I think we should bring snacks this time! Does anyone know who booked the room?
    """

    private func polish(_ original: String, on host: LaggingHost) async throws {
        let reader = DocumentReader(proxy: host)
        let read = try await reader.readWholeDocument()
        XCTAssertEqual(read, original)
        try reader.replace(read, with: "<<" + read + ">>")
        await host.settle()
        XCTAssertEqual(host.document, "<<" + original + ">>")
    }

    /// Emoji take two or more UTF-16 code units, which cursor moves count in.
    func testEmojiAreReadOnce() async throws {
        let original = "Great news 🎉 we shipped it. The team did well 👍🏽. Next up is testing."
        try await polish(original, on: LaggingHost(text: original, moveLatency: .milliseconds(5), afterLag: .milliseconds(5)))
    }

    /// Moves that land after the old fixed 50 ms wait once ended the read
    /// early, and the replacement left the rest of the field behind, starting
    /// a letter in. The text after the cursor catching up mid-step must not
    /// pass for the step.
    func testSlowHostKeepsEveryLetter() async throws {
        let original = Self.prose
        try await polish(original, on: LaggingHost(text: original, moveLatency: .milliseconds(80), afterLag: .milliseconds(40)))
    }

    func testBlankLinesAndListsSurvive() async throws {
        let original = "Shopping list\nEggs\nMilk\n\nCall mom. Ask about Sunday.\n\nDone"
        try await polish(original, on: LaggingHost(text: original, moveLatency: .milliseconds(30), afterLag: .milliseconds(20)))
    }

    /// Steps between blank lines can show nothing, so the read stops at the
    /// first of them while the cursor may have gone further. Nothing read may
    /// be left behind, and nothing past the cursor touched.
    func testTrailingBlankLinesLeaveNothingBehind() async throws {
        let host = LaggingHost(text: "One sentence here.\n\n\n", moveLatency: .milliseconds(5), afterLag: .milliseconds(5))
        let reader = DocumentReader(proxy: host)
        let read = try await reader.readWholeDocument()
        XCTAssertEqual(read, "One sentence here.\n")
        try reader.replace(read, with: "<<" + read + ">>")
        await host.settle()
        XCTAssertEqual(host.document, "<<One sentence here.\n>>\n")
    }

    func testTextPastHiddenBlankLinesKeepsEveryLetter() async throws {
        let host = LaggingHost(text: "Call mom. Ask about Sunday.\n\n\nDone", moveLatency: .milliseconds(5), afterLag: .milliseconds(5))
        let reader = DocumentReader(proxy: host)
        let read = try await reader.readWholeDocument()
        XCTAssertEqual(read, "Call mom. Ask about Sunday.\n")
        try reader.replace(read, with: "<<" + read + ">>")
        await host.settle()
        XCTAssertEqual(host.document, "<<Call mom. Ask about Sunday.\n>>\nDone")
    }

    func testCursorMovedWhilePolishingLeavesTheTextAlone() async throws {
        let original = Self.prose
        let host = LaggingHost(text: original, moveLatency: .milliseconds(5), afterLag: .milliseconds(5))
        let reader = DocumentReader(proxy: host)
        let read = try await reader.readWholeDocument()
        host.adjustTextPosition(byCharacterOffset: -10)
        await host.settle()
        try await Task.sleep(for: .milliseconds(20))
        do {
            try reader.replace(read, with: "polished")
            XCTFail("Replaced text the cursor had left")
        } catch {}
        await host.settle()
        XCTAssertEqual(host.document, original)
    }

    /// The ends of the field wait a few times as long as moves took to show, not a second each.
    func testAQuickHostIsReadQuickly() async throws {
        let original = Self.prose
        func read(_ reader: DocumentReader) async throws -> Duration {
            let start = ContinuousClock.now
            let read = try await reader.readWholeDocument()
            let took = ContinuousClock.now - start
            XCTAssertEqual(read, original)
            return took
        }
        var fixed = DocumentReader(proxy: LaggingHost(text: original, moveLatency: .milliseconds(10), afterLag: .milliseconds(10)))
        fixed.shortestEdgeTimeout = fixed.edgeTimeout
        let before = try await read(fixed)
        let after = try await read(DocumentReader(proxy: LaggingHost(text: original, moveLatency: .milliseconds(10), afterLag: .milliseconds(10))))
        print("POLISH read with full-second edges \(before), with edges that follow the host \(after)")
        XCTAssertLessThan(after, before - .milliseconds(800))
    }

    /// The edge wait follows a slow host up, so its last step still counts.
    func testAVerySlowHostKeepsEveryLetter() async throws {
        let original = Self.prose
        try await polish(original, on: LaggingHost(text: original, moveLatency: .milliseconds(120), afterLag: .milliseconds(60)))
    }
}
