import XCTest

final class KeyboardTouchDecoderTests: XCTestCase {
    private var lexicon: Lexicon { .repository }
    private var centers: [Character: CGPoint] { KeyGeometry.letters.centers }

    private func point(_ letter: Character, dx: CGFloat = 0, dy: CGFloat = 0) -> CGPoint {
        CGPoint(x: centers[letter]!.x + dx, y: centers[letter]!.y + dy)
    }

    private func decode(_ typed: String, _ touches: [CGPoint?]? = nil, likely: [String] = []) -> [String] {
        WordDecoder(lexicon: lexicon)
            .candidates(typed: typed, touches: touches ?? Array(repeating: nil, count: typed.count), likelyWords: likely)
            .map(\.word)
    }

    // MARK: - Geometry

    func testLetterCentersMatchTheKeyGrid() {
        XCTAssertEqual(centers.count, 26)
        XCTAssertEqual(centers["q"], CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(centers["p"], CGPoint(x: 9.5, y: 0.5))
        XCTAssertEqual(centers["a"], CGPoint(x: 1, y: 1.5))
        XCTAssertEqual(centers["z"], CGPoint(x: 2, y: 2.5))
        XCTAssertEqual(centers["m"], CGPoint(x: 8, y: 2.5))
    }

    // MARK: - Letter odds

    func testNextLetterOddsFollowCommonWords() throws {
        let odds = lexicon.nextLetterOdds(after: "th")
        XCTAssertEqual(odds.values.reduce(0, +), 1, accuracy: 0.0001)
        XCTAssertEqual(odds.max { $0.value < $1.value }?.key, "e")
        XCTAssertGreaterThan(try XCTUnwrap(lexicon.nextLetterOdds(after: "q")["u"]), 0.9)
    }

    func testNoOddsAfterAPrefixNoWordStartsWith() {
        XCTAssertTrue(lexicon.nextLetterOdds(after: "xqz").isEmpty)
    }

    // MARK: - Key resolving

    func testEdgeTouchGoesToTheLetterThatFitsTheWord() {
        let odds = lexicon.nextLetterOdds(after: "th")
        let betweenWAndE = CGPoint(x: 2, y: 0.5)
        let betweenEAndR = CGPoint(x: 3, y: 0.5)
        XCTAssertEqual(KeyResolver.resolve(betweenWAndE, nearest: "w", odds: odds), "e")
        XCTAssertEqual(KeyResolver.resolve(betweenEAndR, nearest: "r", odds: odds), "e")
    }

    func testEdgeTouchBetweenRowsGoesToTheLetterThatFitsTheWord() {
        // Low on "i", toward "k": after "q", only "u" makes sense.
        let odds = lexicon.nextLetterOdds(after: "q")
        XCTAssertEqual(KeyResolver.resolve(point("i", dx: -0.45, dy: 0.1), nearest: "i", odds: odds), "u")
    }

    func testCenterTouchAlwaysTypesTheTouchedKey() {
        let odds = lexicon.nextLetterOdds(after: "th")
        XCTAssertEqual(KeyResolver.resolve(point("w"), nearest: "w", odds: odds), "w")
        XCTAssertEqual(KeyResolver.resolve(point("r", dx: -0.2), nearest: "r", odds: odds), "r")
    }

    func testTouchJustOffCenterKeepsTheTouchedKey() {
        let odds = lexicon.nextLetterOdds(after: "th")
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
        XCTAssertEqual(decode("gor", towardF).first, "for")
        XCTAssertEqual(decode("gor", towardT).first, "got")
    }

    func testSwappedLettersAreCorrected() {
        XCTAssertEqual(decode("teh").first, "the")
        XCTAssertEqual(decode("liek").first, "like")
    }

    func testMissingAndExtraLettersAreCorrected() {
        XCTAssertEqual(decode("somthing").first, "something")
        XCTAssertTrue(decode("helo").contains("hello"))
        XCTAssertEqual(decode("thhe").first, "the")
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

    func testLikelyNextWordsWinCloseCalls() {
        let plain = WordDecoder(lexicon: lexicon).candidates(typed: "gor", touches: [nil, nil, nil], likelyWords: [])
        let likely = WordDecoder(lexicon: lexicon).candidates(typed: "gor", touches: [nil, nil, nil], likelyWords: ["got"])
        XCTAssertEqual(plain.first?.word, "for")
        XCTAssertEqual(likely.first?.word, "got")
    }

    func testFarAwayKeysAreNotCandidates() {
        XCTAssertFalse(decode("qqq").contains("the"))
    }

    func testMismatchedTouchesDecodeNothing() {
        XCTAssertTrue(WordDecoder(lexicon: lexicon).candidates(typed: "thw", touches: [nil], likelyWords: []).isEmpty)
    }

    func testNeverSuggestsTheTypedWordItself() {
        XCTAssertFalse(decode("thw").contains("thw"))
        XCTAssertFalse(decode("the").contains("the"))
    }
}
