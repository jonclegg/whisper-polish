import XCTest
@testable import WhisperPolish

final class PolishStyleTests: XCTestCase {

    // Old notes and the default-style setting persist these ids as raw strings.
    func testBuiltInIdsAreStable() {
        XCTAssertEqual(PolishStyle.builtIns.map(\.id),
                       ["email", "reddit", "marketing", "message", "cleanup", "paragraphs"])
    }

    func testOnlyParagraphsStyleIsVerbatim() {
        XCTAssertTrue(PolishStyle.paragraphs.isVerbatim)
        XCTAssertFalse(PolishStyle.cleanup.isVerbatim)
        XCTAssertFalse(PolishStyle(id: "custom-1", name: "X", instruction: "y").isVerbatim)
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
        XCTAssertFalse(PolishStyle(id: "custom-1", name: "X", instruction: "y").isBuiltIn)
    }
}
