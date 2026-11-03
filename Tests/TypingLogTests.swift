import XCTest
@testable import WhisperPolish

final class TypingLogTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory.appendingPathComponent("TypingLogTests/Library/typing-log.jsonl")
        try? FileManager.default.removeItem(at: url)
    }

    override func tearDown() {
        TypingLog.clear(at: url)
        super.tearDown()
    }

    private func entry(_ word: String, finish: TypingLog.Entry.Finish = .typed, bars: [(String, [String])]) -> TypingLog.Entry {
        TypingLog.Entry(
            date: Date(timeIntervalSince1970: 1_800_000_000),
            before: "See you ",
            word: word,
            finish: finish,
            typed: nil,
            bars: bars.map { TypingLog.Entry.Bar(typed: $0.0, shown: $0.1) },
            slowestBarMilliseconds: 12,
            taps: [
                TypingLog.Entry.Tap(target: "s", x: 41.5, y: 140, milliseconds: nil),
                TypingLog.Entry.Tap(target: "bar 0 s", x: 70, y: 37.5, milliseconds: 180),
            ],
            keyboardWidth: 420
        )
    }

    func testEntriesReadBackInOrder() {
        let first = entry("soon", bars: [("", ["soon", "later", "tomorrow"])])
        let second = entry("then", bars: [("", ["at", "in", "on"]), ("t", ["t", "tomorrow", "today"])])
        TypingLog.append(first, to: url)
        TypingLog.append(second, to: url)
        TypingLog.flush()
        XCTAssertEqual(TypingLog.entries(at: url), [first, second])
    }

    func testAFullLogDropsItsOlderHalf() throws {
        let filler = entry(String(repeating: "x", count: 1000), bars: [])
        for _ in 0..<(TypingLog.maximumBytes / 1100 + 10) { TypingLog.append(filler, to: url) }
        let last = entry("last", bars: [])
        TypingLog.append(last, to: url)
        TypingLog.flush()
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        XCTAssertLessThanOrEqual(size, TypingLog.maximumBytes)
        let entries = TypingLog.entries(at: url)
        XCTAssertEqual(entries.last, last)
        XCTAssertLessThan(entries.count, TypingLog.maximumBytes / 1000)
    }

    func testSummaryScoresTheBarLikeTheBenchmark() {
        let summary = TypingLog.summary(of: [
            // Offered before typing: all 5 keystrokes saved.
            entry("soon", bars: [("", ["soon", "later", "tomorrow"])]),
            // Offered after one letter; the first slot, the typed "t", doesn't count.
            entry("then", finish: .tapped, bars: [("", ["at", "in", "on"]), ("t", ["t", "then", "today"])]),
            // Never offered.
            entry("ok", finish: .autocorrected, bars: [("", ["at", "in", "on"]), ("o", ["o", "on", "of"])]),
        ])
        XCTAssertEqual(summary.words, 3)
        XCTAssertEqual(summary.offeredBeforeTyping, 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(summary.keystrokesSaved, 7.0 / 13, accuracy: 1e-9)
        XCTAssertEqual(summary.tapped, 1)
        XCTAssertEqual(summary.autocorrected, 1)
        XCTAssertEqual(summary.reverted, 0)
    }
}
