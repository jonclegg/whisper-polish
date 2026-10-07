import XCTest

/// Types real messages through the keyboard's key resolution, suggestion bar,
/// and autocorrect with simulated sloppy taps and misspellings, and scores how
/// often the intended word ends up in the text. Opt-in: set
/// TEST_RUNNER_KEYBOARD_BENCH to a file from `swift_bench_data.py`.
@MainActor
final class TypingSimulationTests: XCTestCase {
    private struct Bench: Decodable {
        let personal: [String]
        let contacts: [String]
        let scored: [String]
    }

    /// How sloppy the typist is: tap spread in key widths, and how often a word is misspelled outright.
    private struct Level {
        let name: String
        let spread: Double
        let misspellings: Double
    }

    private struct Tally {
        var words = 0
        var correct = 0
        var keystrokes = 0
        var possible = 0
        /// Typed exactly right, then autocorrect changed it.
        var broken = 0
        /// Typed wrong and left wrong.
        var missed = 0
        var typos = 0

        var summary: String {
            String(format: "accuracy %.3f  broke %.3f  savings %.3f  (%d words)",
                   Double(correct) / Double(words), Double(broken) / Double(words), 1 - Double(keystrokes) / Double(possible), words)
        }
    }

    private static let levels = [
        Level(name: "careful", spread: 0.2, misspellings: 0),
        Level(name: "normal", spread: 0.3, misspellings: 0.05),
        Level(name: "sloppy", spread: 0.42, misspellings: 0.1),
    ]
    private static let token = try! NSRegularExpression(pattern: "[A-Za-z]+(?:'[A-Za-z]+)?|[.!?\\n]+")

    func testTypingSimulation() throws {
        guard let path = ProcessInfo.processInfo.environment["KEYBOARD_BENCH"] else {
            throw XCTSkip("Set TEST_RUNNER_KEYBOARD_BENCH to run the typing simulation.")
        }
        let bench = try JSONDecoder().decode(Bench.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let limit = Int(ProcessInfo.processInfo.environment["KEYBOARD_TYPING_LIMIT"] ?? "200")!
        let messages = Array(bench.scored.prefix(limit))
        let only = ProcessInfo.processInfo.environment["KEYBOARD_TYPING_VARIANT"]
        let onlyLevel = ProcessInfo.processInfo.environment["KEYBOARD_TYPING_LEVEL"]
        for (name, settings) in Self.variants() where only == nil || only == name {
            for level in Self.levels where onlyLevel == nil || onlyLevel == level.name {
                let predictor = Predictor()
                predictor.setLexicon(.repository, wordModel: .repository)
                predictor.decoderSettings = settings
                predictor.addNames(bench.contacts)
                for text in bench.personal { learn(text, into: predictor) }
                var random = SplitMix(seed: 7)
                var tally = Tally()
                for text in messages { type(text, with: predictor, level: level, random: &random, tally: &tally) }
                print("TYPING \(name) \(level.name): \(tally.summary)")
            }
        }
    }

    /// Settings to compare; tune by adding variants here.
    private static func variants() -> [(String, WordDecoder.Settings)] {
        [("shipping", WordDecoder.Settings())]
    }

    // MARK: - The typist

    private func type(_ message: String, with predictor: Predictor, level: Level, random: inout SplitMix, tally: inout Tally) {
        var text = ""
        for match in Self.token.matches(in: message, range: NSRange(location: 0, length: (message as NSString).length)) {
            let token = (message as NSString).substring(with: match.range)
            guard token.first!.isLetter else {
                text = text.trimmingCharacters(in: .whitespaces) + (token.contains("\n") ? "\n" : token.prefix(1) + " ")
                continue
            }
            let intended = token.lowercased()
            let final = typeWord(intended, after: text, with: predictor, level: level, random: &random, tally: &tally)
            let context = TypingContext(before: text)
            predictor.learnTyped(final, after: context.previousWords)
            text += final + " "
        }
    }

    /// Taps out `intended` (or a misspelling of it), taking a suggestion as soon as the bar offers the word.
    private func typeWord(_ intended: String, after text: String, with predictor: Predictor, level: Level, random: inout SplitMix, tally: inout Tally) -> String {
        tally.words += 1
        tally.possible += intended.count + 1
        let plan = misspelled(intended.replacingOccurrences(of: "'", with: ""), rate: level.misspellings, random: &random)
        var typed = ""
        var touches: [CGPoint?] = []
        while true {
            let context = TypingContext(before: text + typed)
            let result = predictor.suggestions(for: context, touches: touches, allowsCorrection: true, revert: nil)
            let offered = (typed.isEmpty ? result.suggestions : Array(result.suggestions.dropFirst())).map { $0.text.lowercased() }
            if offered.contains(intended) {
                tally.keystrokes += typed.count + 1
                tally.correct += 1
                return intended
            }
            guard typed.count < plan.count else {
                tally.keystrokes += typed.count + 1
                let final = (result.correction ?? typed).lowercased()
                let typedRight = typed == intended.replacingOccurrences(of: "'", with: "") || typed == intended
                if !typedRight { tally.typos += 1 }
                if final == intended {
                    tally.correct += 1
                } else if typedRight {
                    tally.broken += 1
                    if tally.broken <= 25, ProcessInfo.processInfo.environment["KEYBOARD_TYPING_DEBUG"] != nil {
                        print("BROKE intended \(intended) typed \(typed) final \(final)")
                    }
                } else {
                    tally.missed += 1
                    if tally.missed <= 40, ProcessInfo.processInfo.environment["KEYBOARD_TYPING_DEBUG"] != nil {
                        print("MISS intended \(intended) planned \(plan) typed \(typed) final \(final) offered \(offered)")
                    }
                }
                return final
            }
            let aim = plan[plan.index(plan.startIndex, offsetBy: typed.count)]
            let center = KeyGeometry.letters.centers[aim]!
            let point = CGPoint(x: center.x + level.spread * random.normal(), y: center.y + level.spread * 0.7 * random.normal())
            let nearest = KeyGeometry.letters.centers.min { distance($0.value, point) < distance($1.value, point) }!.key
            let letter = KeyResolver.resolve(point, nearest: nearest, odds: predictor.letterOdds(for: context))
            typed.append(letter)
            touches.append(point)
        }
    }

    /// A real misspelling, not a slip of the finger: letters swapped, dropped, doubled, or a wrong vowel.
    private func misspelled(_ word: String, rate: Double, random: inout SplitMix) -> String {
        var letters = Array(word)
        guard letters.count >= 4, random.uniform() < rate else { return word }
        let at = 1 + Int(random.uniform() * Double(letters.count - 2))
        switch Int(random.uniform() * 4) {
        case 0: letters.swapAt(at, at - 1)
        case 1: letters.remove(at: at)
        case 2: letters.insert(letters[at], at: at)
        default:
            let vowels = Array("aeiou")
            if let index = letters.indices.dropFirst().first(where: { vowels.contains(letters[$0]) }) {
                letters[index] = vowels.filter { $0 != letters[index] }[Int(random.uniform() * 4)]
            }
        }
        return String(letters)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return dx * dx + dy * dy
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

/// A seeded generator, so every variant sees the same taps.
private struct SplitMix {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    mutating func normal() -> Double {
        sqrt(-2 * log(max(uniform(), 1e-12))) * cos(2 * .pi * uniform())
    }
}
