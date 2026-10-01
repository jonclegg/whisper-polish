import XCTest
@testable import WhisperPolish

final class TranscriptTests: XCTestCase {

    // MARK: - Token grouping

    func testGroupingJoinsSubwordTokensAndKeepsTheWeakestConfidence() {
        let words = TranscriptWord.grouping(tokens: [
            (" Kub", 0.9), ("ern", 0.3), ("etes", 0.8), (" is", 0.99), (" up", 0.95), (".", 0.97),
        ])
        XCTAssertEqual(words, [
            TranscriptWord(text: "Kubernetes", confidence: 0.3),
            TranscriptWord(text: "is", confidence: 0.99),
            TranscriptWord(text: "up.", confidence: 0.95),
        ])
    }

    func testGroupingStartsAWordWithoutALeadingSpace() {
        let words = TranscriptWord.grouping(tokens: [("Hi", 0.9), (" there", 0.4)])
        XCTAssertEqual(words.map(\.text), ["Hi", "there"])
    }

    // MARK: - Flagging

    func testOnlyUncertainWordsAreFlaggedWithoutPunctuation() {
        let transcript = Transcript.build(
            text: "Ship it on Friday, okay?",
            words: [
                .init(text: "Ship", confidence: 0.95),
                .init(text: "it", confidence: 0.9),
                .init(text: "on", confidence: 0.9),
                .init(text: "Friday,", confidence: 0.31),
                .init(text: "okay?", confidence: 0.92),
            ]
        )
        XCTAssertEqual(transcript.text, "Ship it on Friday, okay?")
        XCTAssertEqual(transcript.flags.count, 1)
        XCTAssertEqual(transcript.word(for: transcript.flags[0]), "Friday")
        XCTAssertEqual(transcript.flags[0].confidence, 0.31)
        XCTAssertNil(transcript.flags[0].heard)
    }

    func testRepeatedWordFlagsTheOccurrenceThatWasUncertain() {
        let transcript = Transcript.build(
            text: "the plan and the plan",
            words: [
                .init(text: "the", confidence: 0.9),
                .init(text: "plan", confidence: 0.9),
                .init(text: "and", confidence: 0.9),
                .init(text: "the", confidence: 0.9),
                .init(text: "plan", confidence: 0.2),
            ]
        )
        XCTAssertEqual(transcript.flags, [FlaggedWord(location: 17, length: 4, confidence: 0.2, heard: nil)])
    }

    func testSingleLetterWordsAreNotFlagged() {
        let transcript = Transcript.build(text: "I think", words: [.init(text: "I", confidence: 0.1)])
        XCTAssertTrue(transcript.flags.isEmpty)
    }

    func testWordsMissingFromTheTextAreSkipped() {
        let transcript = Transcript.build(text: "hello world", words: [
            .init(text: "goodbye", confidence: 0.1),
            .init(text: "world", confidence: 0.1),
        ])
        XCTAssertEqual(transcript.uncertainWords, ["world"])
    }

    // MARK: - Learned corrections

    func testLearnedCorrectionReplacesOnlyAnUncertainWord() {
        var corrections = PersonalCorrections()
        corrections.learn(heard: "cooper netties", meant: "Kubernetes")
        corrections.learn(heard: "jon", meant: "Jonn")

        let transcript = Transcript.build(
            text: "ask jon and Jon",
            words: [
                .init(text: "ask", confidence: 0.9),
                .init(text: "jon", confidence: 0.2),
                .init(text: "and", confidence: 0.9),
                .init(text: "Jon", confidence: 0.95),
            ],
            corrections: corrections
        )
        XCTAssertEqual(transcript.text, "ask Jonn and Jon")
        XCTAssertEqual(transcript.flags, [FlaggedWord(location: 4, length: 4, confidence: 0.2, heard: "jon")])
    }

    func testLearnedLowercaseWordTakesASentenceCapital() {
        var corrections = PersonalCorrections()
        corrections.learn(heard: "dock", meant: "doc")
        let transcript = Transcript.build(text: "Dock is ready.", words: [.init(text: "Dock", confidence: 0.3)], corrections: corrections)
        XCTAssertEqual(transcript.text, "Doc is ready.")
    }

    func testLearningTheSameWordBackForgetsTheCorrection() {
        var corrections = PersonalCorrections()
        corrections.learn(heard: "jon", meant: "Jonn")
        corrections.learn(heard: "Jon", meant: "jon")
        XCTAssertNil(corrections.correction(for: "jon"))
        XCTAssertTrue(corrections.entries.isEmpty)
    }

    func testCorrectionsStayBoundedAndNewestWins() {
        var corrections = PersonalCorrections()
        for index in 0..<(PersonalCorrections.maxEntries + 5) {
            corrections.learn(heard: "word\(index)", meant: "Term\(index)")
        }
        corrections.learn(heard: "word1", meant: "Changed")
        XCTAssertEqual(corrections.entries.count, PersonalCorrections.maxEntries)
        XCTAssertNil(corrections.correction(for: "word0"))
        XCTAssertEqual(corrections.correction(for: "word1"), "Changed")
        XCTAssertEqual(corrections.vocabulary(limit: 2), ["Changed", "Term204"])
    }

    func testCorrectionsRoundTripThroughJSON() {
        var corrections = PersonalCorrections()
        corrections.learn(heard: "jon", meant: "Jonn")
        XCTAssertEqual(PersonalCorrections.decode(corrections.encoded()), corrections)
        XCTAssertEqual(PersonalCorrections.decode("garbage"), PersonalCorrections())
    }

    // MARK: - Fixing a flagged word

    func testCorrectingAWordShiftsLaterFlags() {
        let transcript = Transcript.build(
            text: "call jon about kube today",
            words: [
                .init(text: "call", confidence: 0.9),
                .init(text: "jon", confidence: 0.2),
                .init(text: "about", confidence: 0.9),
                .init(text: "kube", confidence: 0.3),
            ]
        )
        let fixed = transcript.correcting(transcript.flags[0], to: "Jonathan")
        XCTAssertEqual(fixed.text, "call Jonathan about kube today")
        XCTAssertEqual(fixed.flags.count, 1)
        XCTAssertEqual(fixed.word(for: fixed.flags[0]), "kube")

        let accepted = fixed.accepting(fixed.flags[0])
        XCTAssertEqual(accepted.text, fixed.text)
        XCTAssertTrue(accepted.flags.isEmpty)
    }

    func testCorrectingHandlesEmojiOffsets() {
        let transcript = Transcript.build(text: "👍 sounds goood", words: [.init(text: "goood", confidence: 0.2)])
        let fixed = transcript.correcting(transcript.flags[0], to: "good")
        XCTAssertEqual(fixed.text, "👍 sounds good")
    }

    func testCorrectingAStaleFlagIsANoOp() {
        let transcript = Transcript(text: "short", flags: [])
        let stale = FlaggedWord(location: 10, length: 4, confidence: 0.1, heard: nil)
        XCTAssertEqual(transcript.correcting(stale, to: "x"), transcript)

        let withStaleFlag = Transcript(text: "short", flags: [stale])
        XCTAssertEqual(withStaleFlag.word(for: stale), "")
        XCTAssertTrue(withStaleFlag.uncertainWords.isEmpty)
    }

    func testCorrectionsPersistInUserDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "TranscriptTests"))
        defaults.removePersistentDomain(forName: "TranscriptTests")
        var corrections = PersonalCorrections()
        corrections.learn(heard: "jon", meant: "Jonn")
        corrections.save(to: defaults)
        XCTAssertEqual(PersonalCorrections.load(from: defaults).correction(for: "jon"), "Jonn")
        defaults.removePersistentDomain(forName: "TranscriptTests")
    }
}
