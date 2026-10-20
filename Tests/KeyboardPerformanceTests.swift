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
        var memory = ContextMemory()
        let document = UUID()
        let message = String(repeating: "Thanks so much for the help with dinner. ", count: 12)
        time("context memory, per keystroke", repeats: message.count) { n in
            _ = memory.extend(sentenceHostReport(String(message.prefix(n + 1))), after: "", document: document)
        }
        time("save personal", repeats: 3) { _ in
            _ = try! JSONEncoder().encode(predictor.personalModel)
        }
    }

    /// Ordinary messages, typed a character at a time below.
    private static let paragraph = """
        Hey, just got back from the store. They were out of the bread you like, so I got the sourdough instead. \
        Do you want to come over for dinner tonight? I was thinking we could make pasta and maybe watch a movie after. \
        Let me know what time works for you. I have a meeting until five but I should be free after that. \
        Also, did you hear back from Sarah about the trip next weekend? I think we need to book the hotel soon \
        because the prices keep going up. Thanks again for helping me move last week, I really appreciate it. \
        See you later!
        """

    private struct Timings {
        var samples: [Double] = []

        mutating func time<T>(_ body: () -> T) -> T {
            let start = ContinuousClock.now
            let result = body()
            samples.append(Double((ContinuousClock.now - start) / .microseconds(1)) / 1000)
            return result
        }

        func report(_ label: String) {
            let sorted = samples.sorted()
            func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
            print(String(format: "PERF %@ p50 %.2fms p95 %.2fms max %.2fms over16 %d (n %d)",
                         label, percentile(0.5), percentile(0.95), sorted.last!, sorted.filter { $0 > 16 }.count, sorted.count))
        }
    }

    /// A predictor that has learned a year of typing, when TEST_RUNNER_KEYBOARD_BENCH is set.
    private func loadedPredictor() throws -> Predictor {
        let predictor = Predictor()
        predictor.setLexicon(.repository, wordModel: .repository, personal: try learnedPersonal())
        return predictor
    }

    private func learnedPersonal() throws -> PersonalModel {
        var personal = PersonalModel()
        guard let path = ProcessInfo.processInfo.environment["KEYBOARD_BENCH"] else { return personal }
        let bench = try JSONDecoder().decode(Bench.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        for text in bench.personal {
            var previous: [String] = []
            for word in text.split(whereSeparator: { !$0.isLetter && $0 != "'" }) {
                personal.learn(String(word), after: previous)
                previous.append(word.lowercased())
            }
        }
        return personal
    }

    /// What each keystroke costs: resolving the touched key on touch down, then the bar after the letter lands.
    func testKeystrokeLatency() throws {
        let predictor = try loadedPredictor()
        _ = predictor.suggestions(for: TypingContext(before: ""), touches: [], allowsCorrection: true, revert: nil)
        var touchDown = Timings()
        var bar = Timings()
        var total = Timings()
        var text = ""
        for character in Self.paragraph {
            let start = ContinuousClock.now
            if character.isLetter {
                _ = touchDown.time { predictor.letterOdds(for: TypingContext(before: text)) }
            }
            text.append(character)
            let context = TypingContext(before: text)
            _ = bar.time {
                predictor.suggestions(for: context, touches: Array(repeating: nil, count: context.partialWord.count), allowsCorrection: true, revert: nil)
            }
            total.samples.append(Double((ContinuousClock.now - start) / .microseconds(1)) / 1000)
        }
        touchDown.report("touch down (letter odds)")
        bar.report("bar after a key")
        total.report("per key")
    }

    /// The model's history shrinking or jumping: a backspace across a space, delete
    /// held down in word mode, and the cursor moved to another sentence.
    func testBackspaceAndCursorMoveSpikes() throws {
        let predictor = try loadedPredictor()
        let typed = String(Self.paragraph.prefix(400))
        func bar(_ before: String) {
            let context = TypingContext(before: before)
            _ = predictor.suggestions(for: context, touches: Array(repeating: nil, count: context.partialWord.count), allowsCorrection: true, revert: nil)
        }
        var backspace = Timings()
        let words = typed.split(separator: " ")
        for end in stride(from: words.count - 20, to: words.count, by: 1) {
            let sentence = words[..<end].joined(separator: " ")
            bar(sentence + " ")
            // Deleting the space puts the cursor back in the last word: the history loses it.
            backspace.time { bar(sentence) }
        }
        backspace.report("backspace across a space")

        var deleteWords = Timings()
        bar(typed)
        for end in stride(from: words.count - 1, to: words.count - 21, by: -1) {
            let shorter = words[..<end].joined(separator: " ") + " "
            deleteWords.time { bar(shorter) }
        }
        deleteWords.report("delete held, word by word")

        var cursorMove = Timings()
        let other = String(Self.paragraph.suffix(400))
        for n in 0..<20 {
            let before = n % 2 == 0 ? other : typed
            cursorMove.time { bar(String(before.dropLast(n))) }
        }
        cursorMove.report("cursor moved to another sentence")
    }

    /// What a keyboard opening costs, from reading what was learned to a bar mid-word.
    func testOpenCosts() throws {
        let personal = try learnedPersonal()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("perf-personal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        var save = Timings()
        save.time { personal.save(to: url) }
        save.report("save personal (\((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) bytes)")
        var load = Timings()
        var open = Timings()
        var setLexicon = Timings()
        var names = Timings()
        var firstBar = Timings()
        var firstMidWord = Timings()
        var random = SplitMix(seed: 3)
        let contacts = (0..<1000).map { _ in
            String((0..<(5 + Int(random.uniform() * 4))).map { _ in Character(Unicode.Scalar(UInt8(ascii: "a") + UInt8(random.uniform() * 26))) }).capitalized
        }
        for _ in 0..<5 {
            let start = ContinuousClock.now
            let loaded = load.time { PersonalModel.load(from: url) }
            let predictor = Predictor()
            setLexicon.time { predictor.setLexicon(.repository, wordModel: .repository, personal: loaded) }
            names.time { predictor.addNames(contacts) }
            firstBar.time { _ = predictor.suggestions(for: TypingContext(before: "Do you want to "), touches: [], allowsCorrection: true, revert: nil) }
            firstMidWord.time { _ = predictor.suggestions(for: TypingContext(before: "Do you want to comr"), touches: Array(repeating: nil, count: 4), allowsCorrection: true, revert: nil) }
            open.samples.append(Double((ContinuousClock.now - start) / .microseconds(1)) / 1000)
        }
        load.report("open: load personal")
        setLexicon.report("open: setLexicon")
        names.report("open: add 1000 contact names")
        firstBar.report("open: first bar")
        firstMidWord.report("open: first bar mid-word")
        open.report("open: total to first mid-word bar")
    }
}
