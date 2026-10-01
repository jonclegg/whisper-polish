import XCTest
@testable import WhisperPolish

final class NoteTests: XCTestCase {

    private func result(_ text: String, style: PolishStyle = .email) -> PolishResult {
        PolishResult(text: text, style: style, model: "z-ai/glm-5.2")
    }

    func testUndoAfterFirstPolishReturnsToUnpolished() {
        let note = Note(source: .text, originalText: "rough words")
        note.applyPolish(result("Polished."))
        XCTAssertTrue(note.hasPolishUndo)

        note.undoPolish()
        XCTAssertFalse(note.isPolished)
        XCTAssertNil(note.polishStyleRaw)
        XCTAssertFalse(note.hasPolishUndo)
    }

    func testUndoRestoresThePreviousPolishOnceOnly() {
        let note = Note(source: .text, originalText: "rough words")
        note.applyPolish(result("First.", style: .email))
        note.applyPolish(result("Second.", style: .slack))

        note.undoPolish()
        XCTAssertEqual(note.polishedText, "First.")
        XCTAssertEqual(note.polishStyleRaw, PolishStyle.email.id)
        XCTAssertFalse(note.hasPolishUndo)

        note.undoPolish()
        XCTAssertEqual(note.polishedText, "First.")
    }

    func testTranscriptFlagsRoundTripThroughTheNote() {
        let note = Note(source: .voice, originalText: "")
        let transcript = Transcript.build(text: "call jon", words: [.init(text: "jon", confidence: 0.2)])
        note.transcript = transcript
        XCTAssertEqual(note.originalText, "call jon")
        XCTAssertEqual(note.transcript, transcript)

        note.transcript = transcript.accepting(transcript.flags[0])
        XCTAssertNil(note.transcriptFlagsData)
        XCTAssertTrue(note.transcript.flags.isEmpty)
    }
}
