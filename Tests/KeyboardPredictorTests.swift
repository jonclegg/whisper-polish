import XCTest

@MainActor
final class KeyboardPredictorTests: XCTestCase {
    private func predictor() -> Predictor {
        let predictor = Predictor()
        predictor.setLexicon(.repository, wordModel: .repository, decoder: .repository)
        return predictor
    }

    private func result(_ before: String) -> Predictor.Result {
        let context = TypingContext(before: before)
        return predictor().suggestions(
            for: context,
            touches: Array(repeating: nil, count: context.partialWord.count),
            allowsCorrection: true,
            revert: nil
        )
    }

    func testCorrectsANeighboringKeyTypo() {
        XCTAssertEqual(result("I want thw").correction, "the")
        XCTAssertEqual(result("Thw").correction, "The")
    }

    func testCorrectsWordListFragments() {
        XCTAssertEqual(result("Let's go to thr").correction, "the")
        XCTAssertEqual(result("Thank tou").correction, "you")
    }

    func testCorrectsAStrayLowercaseLetter() {
        XCTAssertEqual(result("Can o").correction, "I")
    }

    func testLeavesACapitalLetterOnItsOwnAlone() {
        XCTAssertNil(result("Plan B").correction)
    }

    func testSplitsRunTogetherWords() {
        XCTAssertEqual(result("letme").correction, "let me")
    }

    func testLeavesKnownWordsAlone() {
        let result = result("I want the")
        XCTAssertNil(result.correction)
        XCTAssertEqual(result.suggestions.first?.text, "the")
    }

    func testOffersTheTypedWordThenTheCorrection() {
        let suggestions = result("wjat").suggestions
        XCTAssertEqual(suggestions.first, Suggestion(text: "wjat", isQuoted: true, learns: true))
        XCTAssertEqual(suggestions.dropFirst().first, Suggestion(text: "what", isAutocorrection: true))
    }

    func testAStrayTapEarlyInAWordStillCompletesIt() {
        XCTAssertTrue(result("Let's meet at the resyau").suggestions.contains { $0.text == "restaurant" })
        XCTAssertTrue(result("See you tomorrow at the airpprt").suggestions.contains { $0.text.hasPrefix("airport") })
    }

    func testLetterOddsFavorLettersThatContinueTheWord() {
        let odds = predictor().letterOdds(for: TypingContext(before: "I want th"))
        XCTAssertEqual(odds.max { $0.value < $1.value }?.key, "e")
    }

    func testLetterOddsFollowTheSentenceSoFar() {
        // On its own "m" could start anything; after "Thanks so" it's "much".
        let odds = predictor().letterOdds(for: TypingContext(before: "Thanks so m"))
        XCTAssertEqual(odds.max { $0.value < $1.value }?.key, "u")
    }

    func testANewFieldDoesNotInheritTheLastOnesSentence() {
        let predictor = predictor()
        let fresh = predictor.suggestions(for: TypingContext(before: ""), touches: [], allowsCorrection: true, revert: nil).suggestions
        _ = predictor.suggestions(for: TypingContext(before: "Thanks so much for the"), touches: [], allowsCorrection: true, revert: nil)
        let again = predictor.suggestions(for: TypingContext(before: ""), touches: [], allowsCorrection: true, revert: nil).suggestions
        XCTAssertEqual(again, fresh)
    }

    private func bar(_ predictor: Predictor, _ before: String) -> [Suggestion] {
        let context = TypingContext(before: before)
        return predictor.suggestions(for: context, touches: Array(repeating: nil, count: context.partialWord.count), allowsCorrection: true, revert: nil).suggestions
    }

    func testBackspacingAcrossASpaceFeedsTheModelNothing() {
        let predictor = predictor()
        _ = bar(predictor, "I want to go to the store and buy ")
        _ = bar(predictor, "I want to go to the store and buy")
        XCTAssertEqual(predictor.lastModelSteps, 0)
        _ = bar(predictor, "I want to go to ")
        XCTAssertEqual(predictor.lastModelSteps, 0)
    }

    func testPickingUpWhereTheModelWasMatchesStartingOver() {
        let typing = predictor()
        let sentence = "I want to go to the store and buy some milk "
        for end in sentence.indices { _ = bar(typing, String(sentence[...end])) }
        let back = "I want to go to the st"
        XCTAssertEqual(bar(typing, back), bar(predictor(), back))
    }

    func testAWindowOnLongTextPicksUpWhereItLeftOff() {
        let predictor = predictor()
        let long = """
            We should get dinner on Friday if you are free. I was thinking about the new place downtown that \
            everyone keeps talking about. My sister went last week and said the pasta was amazing but the wait \
            was really long. Maybe we can book a table for seven so we beat the crowd. Let me know what works \
            and I will call them tomorrow morning before work.
            """
        for (index, character) in zip(long.indices, long) where character == " " { _ = bar(predictor, String(long[...index])) }
        _ = bar(predictor, long)
        XCTAssertGreaterThan(TypingContext(before: long).history.count, TypingContext.historyLength - 1)
        _ = bar(predictor, String(long.dropLast(6)))
        XCTAssertEqual(predictor.lastModelSteps, 0)
        // Moving the cursor back a sentence is still text it was fed, and so is coming back.
        _ = bar(predictor, String(long.dropLast(47)))
        XCTAssertEqual(predictor.lastModelSteps, 0)
        _ = bar(predictor, long)
        XCTAssertEqual(predictor.lastModelSteps, 0)
        _ = bar(predictor, String(long.dropLast(150)))
        XCTAssertEqual(predictor.lastModelSteps, 0)
    }
}
