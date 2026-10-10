import XCTest

/// Times what the keyboard does on the main thread per keystroke. Run optimized
/// (SWIFT_OPTIMIZATION_LEVEL=-O); a phone is a few times slower than a Mac.
/// Set TEST_RUNNER_KEYBOARD_BENCH to time it with a year of learned typing.
@MainActor
final class KeyboardPerformanceTests: XCTestCase {
    private struct Bench: Decodable {
        let personal: [String]
    }

    func testKeystrokeCosts() throws {
        let predictor = Predictor()
        predictor.setLexicon(.repository, wordModel: .repository)
        if let path = ProcessInfo.processInfo.environment["KEYBOARD_BENCH"] {
            let bench = try JSONDecoder().decode(Bench.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            for text in bench.personal {
                var previous: [String] = []
                for word in text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }) {
                    predictor.learnTyped(String(word), after: previous)
                    previous.append(String(word))
                }
            }
        }
        func time(_ label: String, repeats: Int = 20, _ body: (Int) -> Void) {
            let start = Date()
            for n in 0..<repeats { body(n) }
            print(String(format: "PERF %@ %.2fms", label, Date().timeIntervalSince(start) * 1000 / Double(repeats)))
        }
        let sentences = (0..<40).map { "Thanks so much for the help with \($0 % 2 == 0 ? "dinner" : "lunch") and" }
        time("new word (model step + mix + bar)") { n in
            _ = predictor.suggestions(for: TypingContext(before: sentences[n] + " "), touches: [], allowsCorrection: true, revert: nil)
        }
        time("letter odds, nothing typed") { _ in _ = predictor.letterOdds(for: TypingContext(before: "Thanks so much for the ")) }
        time("letter odds, after th") { _ in _ = predictor.letterOdds(for: TypingContext(before: "Thanks so much for the th")) }
        time("bar mid-word, real prefix") { _ in
            _ = predictor.suggestions(for: TypingContext(before: "Thanks so much for the hel"), touches: [nil, nil, nil], allowsCorrection: true, revert: nil)
        }
        time("bar mid-word, typo") { _ in
            _ = predictor.suggestions(for: TypingContext(before: "Thanks so much for the hrlp"), touches: [nil, nil, nil, nil], allowsCorrection: true, revert: nil)
        }
        time("bar, long typo") { _ in
            _ = predictor.suggestions(for: TypingContext(before: "Thanks so much for the somthign"), touches: Array(repeating: nil, count: 8), allowsCorrection: true, revert: nil)
        }
        time("save personal", repeats: 3) { _ in
            _ = try! JSONEncoder().encode(predictor.personalModel)
        }
    }
}
