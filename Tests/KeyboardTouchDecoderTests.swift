import XCTest

final class KeyboardTouchDecoderTests: XCTestCase {
    private var lexicon: Lexicon { .repository }
    private var centers: [Character: CGPoint] { KeyGeometry.letters.centers }

    private func point(_ letter: Character, dx: CGFloat = 0, dy: CGFloat = 0) -> CGPoint {
        CGPoint(x: centers[letter]!.x + dx, y: centers[letter]!.y + dy)
    }

    /// Next-word odds from the word model after `context`.
    private func odds(after context: String) -> [Float] {
        let model = WordModel.repository
        var state = model.start
        model.advance(&state, with: WordModel.boundary)
        for word in context.split(separator: " ") { model.advance(&state, with: model.id(of: String(word))) }
        return model.probabilities(after: state)
    }

    private var decoder: WordDecoder { .repository }

    private func decode(_ typed: String, _ touches: [CGPoint?]? = nil, after context: String = "I think") -> [String] {
        decoder
            .candidates(typed: typed, touches: touches ?? Array(repeating: nil, count: typed.count), odds: odds(after: context))
            .map(\.word)
    }

    /// After "th", as the word model sees it: "the" and "that" lead.
    private let afterTh: [Character: Double] = ["e": 0.5, "a": 0.2, "i": 0.12, "r": 0.08, "o": 0.06, "u": 0.04]
    private let afterQ: [Character: Double] = ["u": 0.98, "a": 0.02]

    // MARK: - Geometry

    func testLetterCentersMatchTheKeyGrid() {
        XCTAssertEqual(centers.count, 26)
        XCTAssertEqual(centers["q"], CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(centers["p"], CGPoint(x: 9.5, y: 0.5))
        XCTAssertEqual(centers["a"], CGPoint(x: 1, y: 1.5))
        XCTAssertEqual(centers["z"], CGPoint(x: 2, y: 2.5))
        XCTAssertEqual(centers["m"], CGPoint(x: 8, y: 2.5))
    }

    private func key(atUnit x: CGFloat, row: Int, bottomRow: BottomRowStyle = .standard, showsNextKeyboard: Bool = false) -> Key? {
        let keys = KeyboardLayout.letters.rows(bottomRow: bottomRow, showsNextKeyboard: showsNextKeyboard)[row]
        return keys.index(atUnit: x).map { keys[$0].key }
    }

    func testTapsAnywhereOnTheSpaceBarTypeASpace() {
        // The space bar is far wider than its neighbors, so its edges are closer to their centers than to its own.
        XCTAssertEqual(key(atUnit: 1.3, row: 3), .space)
        XCTAssertEqual(key(atUnit: 7.9, row: 3), .space)
        XCTAssertEqual(key(atUnit: 1.2, row: 3), .layout(.numbers))
        XCTAssertEqual(key(atUnit: 8.1, row: 3), .returnKey)
        XCTAssertEqual(key(atUnit: 2.6, row: 3, showsNextKeyboard: true), .space)
        XCTAssertEqual(key(atUnit: 2.4, row: 3, showsNextKeyboard: true), .nextKeyboard)
    }

    func testShiftAndDeleteKeepTheirWholeWidth() {
        XCTAssertEqual(key(atUnit: 1.4, row: 2), .shift)
        XCTAssertEqual(key(atUnit: 1.6, row: 2), .character("z"))
        XCTAssertEqual(key(atUnit: 8.6, row: 2), .delete)
        XCTAssertEqual(key(atUnit: 8.4, row: 2), .character("m"))
    }

    func testRowEndsBelongToTheEndKeys() {
        XCTAssertEqual(key(atUnit: 0.1, row: 1), .character("a"))
        XCTAssertEqual(key(atUnit: 9.9, row: 1), .character("l"))
        XCTAssertEqual(key(atUnit: -1, row: 0), .character("q"))
        XCTAssertEqual(key(atUnit: 11, row: 0), .character("p"))
    }

    // MARK: - Key resolving

    func testEdgeTouchGoesToTheLetterThatFitsTheWord() {
        let odds = afterTh
        let betweenWAndE = CGPoint(x: 2, y: 0.5)
        let betweenEAndR = CGPoint(x: 3, y: 0.5)
        XCTAssertEqual(KeyResolver.resolve(betweenWAndE, nearest: "w", odds: odds), "e")
        XCTAssertEqual(KeyResolver.resolve(betweenEAndR, nearest: "r", odds: odds), "e")
    }

    func testEdgeTouchBetweenRowsGoesToTheLetterThatFitsTheWord() {
        // Low on "i", toward "k": after "q", only "u" makes sense.
        let odds = afterQ
        XCTAssertEqual(KeyResolver.resolve(point("i", dx: -0.45, dy: 0.1), nearest: "i", odds: odds), "u")
    }

    func testCenterTouchAlwaysTypesTheTouchedKey() {
        let odds = afterTh
        XCTAssertEqual(KeyResolver.resolve(point("w"), nearest: "w", odds: odds), "w")
        XCTAssertEqual(KeyResolver.resolve(point("r", dx: -0.2), nearest: "r", odds: odds), "r")
    }

    func testTouchJustOffCenterKeepsTheTouchedKey() {
        let odds = afterTh
        XCTAssertEqual(KeyResolver.resolve(point("r", dx: -0.33), nearest: "r", odds: odds), "r")
    }

    func testWithoutOddsTheNearestKeyWins() {
        XCTAssertEqual(KeyResolver.resolve(CGPoint(x: 2, y: 0.5), nearest: "w", odds: [:]), "w")
    }

    // MARK: - Word decoding

    func testDecodesNeighboringKeyTypos() {
        XCTAssertEqual(decode("thw").first, "the")
        XCTAssertEqual(decode("hrllo").first, "hello")
        XCTAssertEqual(decode("wjat").first, "what")
        XCTAssertEqual(decode("abd").first, "and")
        XCTAssertEqual(decode("yoy").first, "you")
    }

    func testWhereTheFingerLandedPicksTheWord() {
        // "gor" is one key from both "for" and "got".
        let towardF = [point("g", dx: -0.45), nil, nil]
        let towardT = [nil, nil, point("r", dx: 0.45)]
        XCTAssertEqual(decode("gor", towardF, after: "").first, "for")
        XCTAssertEqual(decode("gor", towardT, after: "").first, "got")
    }

    func testSwappedLettersAreCorrected() {
        XCTAssertEqual(decode("teh").first, "the")
        XCTAssertEqual(decode("liek").first, "like")
    }

    func testMissingAndExtraLettersAreCorrected() {
        XCTAssertEqual(decode("somthing").first, "something")
        XCTAssertTrue(decode("helo", after: "").contains("hello"))
        XCTAssertEqual(decode("thhe").first, "the")
    }

    func testTwoSlipsInOneWordAreCorrected() {
        XCTAssertEqual(decode("somthign").first, "something")
        XCTAssertEqual(decode("probly").first, "probably")
        XCTAssertEqual(decode("tomorow").first, "tomorrow")
        XCTAssertEqual(decode("esl", after: "or").first, "else")
    }

    func testListFragmentsAreNeverFixes() {
        XCTAssertFalse(decode("esl").contains("el"))
        XCTAssertFalse(decode("tr").contains("rt"))
        XCTAssertFalse(decode("c").contains("co"))
    }

    func testAStrayLetterBecomesAShortWord() {
        XCTAssertEqual(decode("o").first, "i")
        XCTAssertEqual(decode("t", after: "I want").first, "to")
        XCTAssertTrue(decode("z").isEmpty)
    }

    func testOnlyRealWordsCount() {
        XCTAssertTrue(lexicon.isWord("the"))
        XCTAssertTrue(lexicon.isWord("ok"))
        XCTAssertTrue(lexicon.isWord("A"))
        XCTAssertTrue(lexicon.isWord("tome"))
        XCTAssertFalse(lexicon.isWord("thr"))
        XCTAssertFalse(lexicon.isWord("el"))
        XCTAssertFalse(lexicon.isWord("s"))
        XCTAssertTrue(lexicon.contains("thr"))
    }

    func testRunTogetherWordsAreSplit() {
        XCTAssertEqual(decode("letme").first, "let me")
        XCTAssertEqual(decode("ofthe").first, "of the")
    }

    func testNeverRewritesMostOfAWord() {
        XCTAssertFalse(decode("letme").contains("perks"))
        XCTAssertFalse(decode("letme").contains("merle"))
    }

    func testNeverCorrectsToAStrayLetter() {
        XCTAssertFalse(decode("tr").contains("t"))
        XCTAssertFalse(decode("tr").contains("r"))
    }

    func testWordsWithApostrophesDecodeNothing() {
        XCTAssertTrue(decode("dont'").isEmpty)
    }

    func testTheSentenceSettlesCloseCalls() {
        XCTAssertEqual(decode("gor", after: "thanks").first, "for")
        XCTAssertEqual(decode("gor", after: "I").first, "got")
    }

    func testFarAwayKeysAreNotCandidates() {
        XCTAssertFalse(decode("qqq").contains("the"))
    }

    func testMismatchedTouchesDecodeNothing() {
        XCTAssertTrue(decoder.candidates(typed: "thw", touches: [nil], odds: odds(after: "")).isEmpty)
    }

    func testNeverSuggestsTheTypedWordItself() {
        XCTAssertFalse(decode("thw").contains("thw"))
        XCTAssertFalse(decode("the").contains("the"))
    }

    // MARK: - The trie

    /// The trie walk drops branches early, so check it against a plain edit
    /// distance over every word, on sloppy taps of real words.
    func testTheTrieFindsWhatASearchOfEveryWordWould() {
        let settings = WordDecoder.Settings()
        let odds = odds(after: "I think")
        var random = SplitMix(seed: 9)
        let aims = ["restaurant", "because", "tomorrow", "the", "what", "hello", "probably", "it", "something", "meeting"]
        for aim in aims + aims {
            var typed = ""
            var touches: [CGPoint?] = []
            for letter in aim {
                let (point, nearest) = sloppyTap(at: letter, spread: 0.42, random: &random)
                typed.append(nearest)
                touches.append(point)
            }
            let letters = Array(typed.utf8)
            let maxLoss = letters.count >= 3 ? settings.maxEditLoss : settings.maxShortWordLoss
            let maxEdits = Int(maxLoss / settings.editPenalty)
            var expected: [(word: String, score: Double)] = []
            let literal = decoder.spatialScore(typed: typed, touches: touches)!
            for length in max(1, letters.count - maxEdits)...(letters.count + maxEdits) {
                let bucket = lexicon.words(ofLength: length)
                for (word, rank) in zip(bucket.words, bucket.ranks) where word != letters && Lexicon.isWord(word, rank: rank) {
                    let text = String(decoding: word, as: UTF8.self)
                    let startsNear = cost(typed, touches, 0, text.first!).isFinite || (letters.count > 1 && word[0] == letters[1]) || (word.count > 1 && word[1] == letters[0])
                    let loss = editLoss(typed, touches, to: text, settings: settings)
                    guard startsNear, loss <= maxLoss else { continue }
                    expected.append((text, literal - loss + decoder.prior(WordModel.repository.ids[text], odds: odds)))
                }
            }
            let found = decoder.decode(typed: typed, touches: touches, odds: odds, limit: 1000).candidates.filter { !$0.word.contains(" ") }
            XCTAssertEqual(Set(found.map(\.word)), Set(expected.map(\.word)), "typed \(typed) for \(aim)")
            for candidate in found {
                let score = expected.first { $0.word == candidate.word }?.score ?? .nan
                XCTAssertEqual(candidate.score, score, accuracy: 1e-9, "\(candidate.word) for \(typed)")
            }
        }
    }

    func testNearMissesOfAWordsStartAreFound() {
        let prefixes = decoder.decode(typed: "resyau", touches: Array(repeating: nil, count: 6), odds: odds(after: "Let's meet at the")).prefixes
        XCTAssertTrue(prefixes.contains { prefix in
            prefix.words.contains { decoder.wordIds[$0] == WordModel.repository.ids["restaurant"] }
        })
    }

    private func cost(_ typed: String, _ touches: [CGPoint?], _ index: Int, _ letter: Character) -> Double {
        let typedLetter = Array(typed)[index]
        guard letter != typedLetter else { return 0 }
        let point = touches[index] ?? centers[typedLetter]!
        let likelihood = TouchModel.logLikelihood(of: point, aimingAt: centers[letter]!)
        return likelihood >= TouchModel.farthest ? TouchModel.logLikelihood(of: point, aimingAt: centers[typedLetter]!) - likelihood : .infinity
    }

    /// The decoder's edit distance, worked out in full.
    private func editLoss(_ typed: String, _ touches: [CGPoint?], to word: String, settings: WordDecoder.Settings) -> Double {
        let t = Array(typed)
        let w = Array(word)
        var d = [[Double]](repeating: [Double](repeating: 0, count: w.count + 1), count: t.count + 1)
        for i in 0...t.count {
            for j in 0...w.count {
                guard i > 0, j > 0 else {
                    d[i][j] = Double(i + j) * settings.editPenalty
                    continue
                }
                var value = min(d[i - 1][j], d[i][j - 1]) + settings.editPenalty
                value = min(value, d[i - 1][j - 1] + cost(typed, touches, i - 1, w[j - 1]))
                if i > 1, j > 1, t[i - 1] == w[j - 2], t[i - 2] == w[j - 1] { value = min(value, d[i - 2][j - 2] + settings.swapPenalty) }
                d[i][j] = value
            }
        }
        return d[t.count][w.count]
    }
}
