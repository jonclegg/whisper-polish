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

    private var decoder: WordDecoder {
        WordDecoder(lexicon: lexicon) { WordModel.repository.ids[$0] }
    }

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
}
