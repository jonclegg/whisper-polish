import XCTest

/// Replays real messages through the keyboard's predictor and scores the bar
/// it actually shows, with the metrics `scripts/keyboard-model/bench.py` uses.
/// Opt-in: set TEST_RUNNER_KEYBOARD_BENCH to a file from `swift_bench_data.py`.
@MainActor
final class PredictionBenchmarkTests: XCTestCase {
    private struct Bench: Decodable {
        let personal: [String]
        let contacts: [String]
        let scored: [String]
    }

    private static let token = try! NSRegularExpression(pattern: "[A-Za-z]+(?:'[A-Za-z]+)?|[.!?\\n]+")

    func testPredictionBenchmark() throws {
        guard let path = ProcessInfo.processInfo.environment["KEYBOARD_BENCH"] else {
            throw XCTSkip("Set TEST_RUNNER_KEYBOARD_BENCH to run the prediction benchmark.")
        }
        let bench = try JSONDecoder().decode(Bench.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let predictor = Predictor()
        predictor.setLexicon(.repository, wordModel: .repository, decoder: .repository)
        predictor.addNames(bench.contacts)
        for text in bench.personal { learn(text, into: predictor) }

        var words = 0
        var keystrokes = 0
        var saved = 0
        var offeredBeforeTyping = 0
        // Offered words whose case differs from how the message wrote them, away from a sentence start.
        var caseJudged = 0
        var wrongCase = 0
        let document = UUID()
        for text in bench.scored {
            var memory = ContextMemory()
            var fed = 0
            for (word, start) in Self.words(in: text) {
                let lower = word.lowercased()
                words += 1
                keystrokes += lower.count + 1
                for typed in 0..<lower.count {
                    let prefix = String(word.prefix(typed))
                    var before = String(text.utf16.prefix(start))! + prefix
                    // KEYBOARD_BENCH_HOST=sentence scores what a host like Messages reports, the
                    // current sentence; =memory adds the keyboard's memory of earlier sentences.
                    switch ProcessInfo.processInfo.environment["KEYBOARD_BENCH_HOST"] {
                    case "sentence": before = sentenceHostReport(before)
                    case "memory":
                        // The keyboard sees every keystroke, punctuation and line breaks included.
                        let characters = Array(before)
                        while fed < characters.count {
                            fed += 1
                            _ = memory.extend(sentenceHostReport(String(characters[..<fed])), after: "", document: document)
                        }
                        before = memory.text
                    default: break
                    }
                    let context = TypingContext(before: before)
                    let shown = predictor.suggestions(for: context, touches: Array(repeating: nil, count: prefix.count), allowsCorrection: ProcessInfo.processInfo.environment["KEYBOARD_BENCH_CORRECTION"] != "off", revert: nil).suggestions
                    // Once letters are typed, the first slot is what's typed, not a suggestion.
                    let offeredText = (typed == 0 ? shown : Array(shown.dropFirst())).map(\.text)
                    if let match = offeredText.first(where: { $0.lowercased() == lower }) {
                        if !context.startsSentence, lower != "i", !lower.hasPrefix("i'"), word.dropFirst().allSatisfy({ !$0.isUppercase }) {
                            caseJudged += 1
                            if match != word { wrongCase += 1 }
                        }
                        saved += lower.count - typed
                        if typed == 0 { offeredBeforeTyping += 1 }
                        break
                    }
                }
            }
            learn(text, into: predictor)
        }
        let savings = Double(saved) / Double(keystrokes)
        let bar = Double(offeredBeforeTyping) / Double(words)
        print(String(format: "BENCH words %d savings %.3f bar %.3f wrongCase %.4f (%d of %d)", words, savings, bar, Double(wrongCase) / Double(caseJudged), wrongCase, caseJudged))
    }

    /// The same messages typed with sloppy taps, at `TypingSimulationTests`' "normal" spread,
    /// through key resolution: how often the bar offers the intended word and the keystrokes
    /// that saves, and how often autocorrect leaves a word typed to its end right. The clean
    /// benchmark above types every letter right, which no thumb does.
    func testNoisyTapBenchmark() throws {
        guard let path = ProcessInfo.processInfo.environment["KEYBOARD_BENCH"] else {
            throw XCTSkip("Set TEST_RUNNER_KEYBOARD_BENCH to run the noisy-tap benchmark.")
        }
        let bench = try JSONDecoder().decode(Bench.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let spread = Double(ProcessInfo.processInfo.environment["KEYBOARD_BENCH_SPREAD"] ?? "0.3")!
        let predictor = Predictor()
        predictor.setLexicon(.repository, wordModel: .repository, decoder: .repository)
        predictor.addNames(bench.contacts)
        for text in bench.personal { learn(text, into: predictor) }

        var random = SplitMix(seed: 11)
        var words = 0
        var keystrokes = 0
        var saved = 0
        // Words of three or more letters offered by the time two letters are tapped.
        var longWords = 0
        var offeredEarly = 0
        // Words tapped to their end: right as tapped or not, and right after autocorrect.
        var autocorrectRight = 0
        var tappedWrong = 0
        var fixed = 0
        var broken = 0
        let document = UUID()
        for text in bench.scored {
            var memory = ContextMemory()
            var fed = 0
            for (word, start) in Self.words(in: text) {
                let intended = word.lowercased()
                let letters = intended.replacingOccurrences(of: "'", with: "")
                words += 1
                keystrokes += intended.count + 1
                if letters.count >= 3 { longWords += 1 }
                var head = String(text.utf16.prefix(start))!
                if ProcessInfo.processInfo.environment["KEYBOARD_BENCH_HOST"] == "memory" {
                    let characters = Array(head)
                    while fed < characters.count {
                        fed += 1
                        _ = memory.extend(sentenceHostReport(String(characters[..<fed])), after: "", document: document)
                    }
                    head = memory.text
                }
                var typed = ""
                var touches: [CGPoint?] = []
                var offered = false
                var result = Predictor.Result(suggestions: [], correction: nil)
                for aim in letters + "\u{0}" {
                    let context = TypingContext(before: head + typed)
                    result = predictor.suggestions(for: context, touches: touches, allowsCorrection: true, revert: nil)
                    if !offered, (typed.isEmpty ? result.suggestions : Array(result.suggestions.dropFirst())).contains(where: { $0.text.lowercased() == intended }) {
                        offered = true
                        saved += intended.count - typed.count
                        if typed.count <= 2, letters.count >= 3 { offeredEarly += 1 }
                    }
                    guard aim != "\u{0}" else { break }
                    let (point, nearest) = sloppyTap(at: aim, spread: spread, random: &random)
                    typed.append(KeyResolver.resolve(point, nearest: nearest, odds: predictor.letterOdds(for: context)))
                    touches.append(point)
                }
                let final = (result.correction ?? typed).lowercased()
                if final == intended { autocorrectRight += 1 }
                if typed != letters {
                    tappedWrong += 1
                    if final == intended { fixed += 1 }
                } else if final != intended, final != typed {
                    broken += 1
                }
            }
            learn(text, into: predictor)
        }
        print(String(
            format: "NOISY spread %.2f words %d savings %.3f early %.3f autocorrect %.3f tappedWrong %.3f fixed %.3f broke %.4f",
            spread, words, Double(saved) / Double(keystrokes), Double(offeredEarly) / Double(longWords),
            Double(autocorrectRight) / Double(words), Double(tappedWrong) / Double(words),
            Double(fixed) / Double(max(tappedWrong, 1)), Double(broken) / Double(words)
        ))
    }

    /// Each word and where it starts (in UTF-16), within its message.
    private static func words(in text: String) -> [(String, Int)] {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return token.matches(in: text, range: range).compactMap { match in
            let token = (text as NSString).substring(with: match.range)
            return token.first!.isLetter ? (token, match.range.location) : nil
        }
    }

    private func learn(_ text: String, into predictor: Predictor) {
        var previous: [String] = []
        for match in Self.token.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
            let token = (text as NSString).substring(with: match.range)
            guard token.first!.isLetter else {
                previous = []
                continue
            }
            predictor.learnTyped(token, after: previous)
            previous.append(token.lowercased())
        }
    }
}
