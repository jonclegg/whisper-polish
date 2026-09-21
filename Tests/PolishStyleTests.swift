import XCTest
@testable import WhisperPolish

final class PolishStyleTests: XCTestCase {

    // Old notes and the default-style setting persist these ids as raw strings.
    func testBuiltInIdsAreStable() {
        XCTAssertEqual(Set(PolishStyle.builtIns.map(\.id)),
                       ["native", "proofread", "professional",
                        "email", "reddit", "marketing", "message", "cleanup",
                        "slack", "bullets", "blog", "social", "formal"])
        XCTAssertEqual(PolishStyle.builtIns.prefix(3).map(\.id),
                       ["native", "proofread", "professional"])
    }

    func testCustomStylesRoundTripThroughJSON() {
        let styles = [
            PolishStyle(id: "custom-1", name: "Standup update", instruction: "Terse, past tense."),
            PolishStyle(id: "custom-2", name: "Poem", instruction: "Rhyme it."),
        ]
        let json = PolishStyle.encodeCustom(styles)
        XCTAssertEqual(PolishStyle.decodeCustom(json), styles)
    }

    func testDecodeCustomToleratesGarbageAndEmpty() {
        XCTAssertEqual(PolishStyle.decodeCustom(""), [])
        XCTAssertEqual(PolishStyle.decodeCustom("not json"), [])
    }

    func testAllCombinesBuiltInsAndCustom() {
        let json = PolishStyle.encodeCustom([PolishStyle(id: "custom-1", name: "X", instruction: "y")])
        let all = PolishStyle.all(customJSON: json)
        XCTAssertEqual(all.count, PolishStyle.builtIns.count + 1)
        XCTAssertEqual(all.last?.name, "X")
    }

    func testFindResolvesBuiltInCustomAndUnknown() {
        let json = PolishStyle.encodeCustom([PolishStyle(id: "custom-1", name: "X", instruction: "y")])
        XCTAssertEqual(PolishStyle.find(id: "email", customJSON: json), .email)
        XCTAssertEqual(PolishStyle.find(id: "custom-1", customJSON: json)?.name, "X")
        XCTAssertNil(PolishStyle.find(id: "deleted-style", customJSON: json))
    }

    func testBuiltInFlag() {
        XCTAssertTrue(PolishStyle.email.isBuiltIn)
        XCTAssertTrue(PolishStyle.native.isBuiltIn)
        XCTAssertFalse(PolishStyle(id: "custom-1", name: "X", instruction: "y").isBuiltIn)
    }

    func testFixitStylesUseCompleteEditorPrompts() {
        XCTAssertTrue(PolishStyle.native.usesCompleteEditorPrompt)
        XCTAssertTrue(PolishStyle.proofread.usesCompleteEditorPrompt)
        XCTAssertTrue(PolishStyle.professional.usesCompleteEditorPrompt)
        XCTAssertFalse(PolishStyle.email.usesCompleteEditorPrompt)
        XCTAssertFalse(PolishStyle(id: "custom-1", name: "X", instruction: "y").usesCompleteEditorPrompt)
    }

    func testFixitStyleInstructionsMatchFixitPrompts() {
        XCTAssertTrue(PolishStyle.native.instruction.contains("You are a native English editor."))
        XCTAssertTrue(PolishStyle.native.instruction.contains("Return only the edited text."))
        XCTAssertTrue(PolishStyle.native.instruction.contains("<<double angle brackets>>"))
        XCTAssertTrue(PolishStyle.proofread.instruction.contains("smallest possible edit"))
        XCTAssertTrue(PolishStyle.proofread.instruction.contains("Return only the edited text."))
        XCTAssertTrue(PolishStyle.professional.instruction.contains("workplace-appropriate"))
        XCTAssertTrue(PolishStyle.professional.instruction.contains("Return only the edited text."))
        XCTAssertEqual(PolishStyle.native.name, "Sound native")
        XCTAssertEqual(PolishStyle.proofread.name, "Proofread")
        XCTAssertEqual(PolishStyle.professional.name, "Make professional")
    }
}
