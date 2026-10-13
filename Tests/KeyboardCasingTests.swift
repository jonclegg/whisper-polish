import XCTest

/// How the bar capitalizes the words it offers away from a sentence start.
@MainActor
final class KeyboardCasingTests: XCTestCase {
    private func predictor() -> Predictor {
        let predictor = Predictor()
        predictor.setLexicon(.repository, wordModel: .repository)
        return predictor
    }

    private func offered(_ predictor: Predictor, _ before: String) -> [String] {
        let context = TypingContext(before: before)
        return predictor.suggestions(for: context, touches: Array(repeating: nil, count: context.partialWord.count), allowsCorrection: true, revert: nil)
            .suggestions.map(\.text)
    }

    func testContactsSplitIntoWordsDontCapitalizeEverydayWords() {
        let predictor = predictor()
        // Business contacts arrive as words: "Time Warner", "Up Your Game".
        predictor.addNames(["For", "Time", "Up", "Rena"])
        XCTAssertEqual(predictor.written("for", after: "thanks"), "for")
        XCTAssertEqual(predictor.written("time", after: "what"), "time")
        XCTAssertEqual(predictor.written("rena", after: "to"), "Rena")
        XCTAssertFalse(offered(predictor, "Thanks f").contains("For"))
    }

    func testTheWordListOnlyCapitalizesWordsThatUsuallyAre() {
        let lexicon = Lexicon.repository
        for word in ["mom", "dad", "yep", "nope", "hmm", "uncle", "fire", "doctor", "sir", "ok"] {
            XCTAssertEqual(lexicon.displayForm(of: word), word, word)
        }
        for word in ["Monday", "John", "English", "TV", "Christmas", "I'm", "LeBron", "iPhone", "Avenue"] {
            XCTAssertEqual(lexicon.displayForm(of: word.lowercased()), word, word)
        }
    }

    func testSomeWordsAreNamesOnlyAfterAParticularWord() {
        let lexicon = Lexicon.repository
        XCTAssertEqual(lexicon.capitalizedForm(of: "may", after: "in"), "May")
        XCTAssertEqual(lexicon.capitalizedForm(of: "states", after: "united"), "States")
        XCTAssertNil(lexicon.capitalizedForm(of: "may", after: "this"))
        XCTAssertNil(lexicon.capitalizedForm(of: "states", after: "it"))
    }

    func testTheBarFollowsHowYouWriteAWord() {
        let predictor = predictor()
        for _ in 0..<3 {
            predictor.learnTyped("Rena", after: ["with"])
            predictor.learnTyped("ok", after: ["is"])
        }
        XCTAssertEqual(predictor.written("rena", after: "with"), "Rena")
        XCTAssertEqual(predictor.written("ok", after: "is"), "ok")
        // A sentence start says nothing about how a word is written.
        for _ in 0..<3 { predictor.learnTyped("Pizza", after: []) }
        XCTAssertEqual(predictor.written("pizza", after: "some"), "pizza")
    }

    func testAHabitCanChange() {
        var personal = PersonalModel()
        for _ in 0..<3 { personal.learn("Mom", after: ["my"]) }
        XCTAssertEqual(personal.writtenForm(of: "mom"), "Mom")
        for _ in 0..<5 { personal.learn("mom", after: ["my"]) }
        XCTAssertEqual(personal.writtenForm(of: "mom"), "mom")
    }

    func testModelsSavedBeforeCasingWasLearnedStillLoad() throws {
        let old = #"{"typed":{"hello":2},"wordsTyped":2,"continuation":{},"continuationTotal":0,"bigrams":{},"trigrams":{},"names":[]}"#
        let personal = try JSONDecoder().decode(PersonalModel.self, from: Data(old.utf8))
        XCTAssertTrue(personal.isLearned("hello"))
        XCTAssertNil(personal.writtenForm(of: "hello"))
    }
}
