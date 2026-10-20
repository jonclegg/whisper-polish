import XCTest

@MainActor
final class KeyboardLearnedWordsTests: XCTestCase {
    /// Where `Predictor` keeps words kept from the bar.
    private let learnedKey = "KeyboardLearnedWords"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: learnedKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: learnedKey)
        super.tearDown()
    }

    private func predictor() -> Predictor {
        let predictor = Predictor()
        predictor.setLexicon(.repository, wordModel: .repository, decoder: .repository)
        return predictor
    }

    private func suggestions(_ predictor: Predictor, _ before: String) -> [Suggestion] {
        let context = TypingContext(before: before)
        return predictor.suggestions(
            for: context,
            touches: Array(repeating: nil, count: context.partialWord.count),
            allowsCorrection: true,
            revert: nil
        ).suggestions
    }

    func testAWordKeptFromTheBarIsListedAndSuggested() {
        let predictor = predictor()
        XCTAssertEqual(predictor.learnedWords, [])
        XCTAssertEqual(suggestions(predictor, "I saw a zorbly").first, Suggestion(text: "zorbly", isQuoted: true, learns: true))

        predictor.learn("Zorbly")
        XCTAssertEqual(predictor.learnedWords, ["Zorbly"])
        XCTAssertEqual(suggestions(predictor, "I saw a zorbly").first, Suggestion(text: "zorbly"))
        XCTAssertTrue(suggestions(predictor, "I saw a zorb").contains { $0.text == "Zorbly" })
        // It's remembered for the next time the keyboard opens.
        XCTAssertEqual(self.predictor().learnedWords, ["Zorbly"])
    }

    func testForgettingAKeptWordMakesItUnknownAgain() {
        let predictor = predictor()
        predictor.learn("Zorbly")
        predictor.forget(["zorbly"])
        XCTAssertEqual(predictor.learnedWords, [])
        XCTAssertEqual(suggestions(predictor, "I saw a zorbly").first, Suggestion(text: "zorbly", isQuoted: true, learns: true))
        XCTAssertFalse(suggestions(predictor, "I saw a zorb").contains { $0.text.lowercased() == "zorbly" })
        XCTAssertEqual(self.predictor().learnedWords, [])
    }

    func testMadeUpWordsTypedTwiceAreListedButRealWordsAreNot() {
        let predictor = predictor()
        predictor.learnTyped("blorptastic", after: ["so"])
        XCTAssertEqual(predictor.learnedWords, [], "Once isn't enough to learn a word")
        predictor.learnTyped("blorptastic", after: ["so"])
        predictor.learnTyped("pizza", after: ["more"])
        predictor.learnTyped("pizza", after: ["more"])
        XCTAssertEqual(predictor.learnedWords, ["blorptastic"])
        XCTAssertTrue(suggestions(predictor, "That was so blorp").contains { $0.text == "blorptastic" })
    }

    func testASlipOfACommonWordTakesLongerToLearn() {
        let predictor = predictor()
        for _ in 0..<(Predictor.timesToLearnSlip - 1) { predictor.learnTyped("becuase", after: ["just"]) }
        XCTAssertEqual(predictor.learnedWords, [], "\"becuase\" is one swap from \"because\"")
        XCTAssertEqual(suggestions(predictor, "just becuase").dropFirst().first?.text, "because")
        predictor.learnTyped("becuase", after: ["just"])
        XCTAssertEqual(predictor.learnedWords, ["becuase"])
    }

    func testForgettingATypedWordStopsSuggestingItUntilItsTypedOftenAgain() {
        let predictor = predictor()
        predictor.learnTyped("blorptastic", after: ["so"])
        predictor.learnTyped("blorptastic", after: ["so"])
        predictor.forget(["Blorptastic"])
        XCTAssertEqual(predictor.learnedWords, [])
        XCTAssertFalse(predictor.personalModel.isLearned("blorptastic"))
        XCTAssertFalse(suggestions(predictor, "That was so blorp").contains { $0.text == "blorptastic" })

        predictor.learnTyped("blorptastic", after: ["so"])
        XCTAssertEqual(predictor.learnedWords, [])
        predictor.learnTyped("blorptastic", after: ["so"])
        XCTAssertEqual(predictor.learnedWords, ["blorptastic"])
    }

    func testForgettingNothingChangesNothing() {
        let predictor = predictor()
        predictor.learn("Zorbly")
        predictor.forget([])
        XCTAssertEqual(predictor.learnedWords, ["Zorbly"])
    }

    func testPersonalModelForgetsEveryTraceOfAWord() {
        var withWord = PersonalModel()
        withWord.learn("cat", after: ["i"])
        withWord.learn("zorbly", after: ["i", "love"])
        withWord.learn("love", after: ["zorbly"])
        withWord.forget("zorbly")
        var without = PersonalModel()
        without.learn("cat", after: ["i"])

        let vocabulary = ["cat": 0, "zorbly": 1, "love": 2]
        for previous in [["i"], ["i", "love"], ["zorbly"], []] {
            XCTAssertEqual(
                withWord.probabilities(after: previous, vocabulary: vocabulary, count: 3),
                without.probabilities(after: previous, vocabulary: vocabulary, count: 3),
                "after \(previous)"
            )
        }
        XCTAssertNil(withWord.typed["zorbly"])
    }
}
