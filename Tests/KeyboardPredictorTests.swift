import XCTest

@MainActor
final class KeyboardPredictorTests: XCTestCase {
    private func predictor() -> Predictor {
        let predictor = Predictor()
        predictor.setLexicon(.repository, wordModel: .repository)
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

    func testLetterOddsFavorLettersThatContinueTheWord() {
        let odds = predictor().letterOdds(for: TypingContext(before: "I want th"))
        XCTAssertEqual(odds.max { $0.value < $1.value }?.key, "e")
    }

    func testLetterOddsFollowTheSentenceSoFar() {
        // "Thanks" and "That's" open sentences far more often than "The".
        let odds = predictor().letterOdds(for: TypingContext(before: "Th"))
        XCTAssertEqual(odds.max { $0.value < $1.value }?.key, "a")
    }
}
