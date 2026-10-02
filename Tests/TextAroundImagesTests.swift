import XCTest

final class TextAroundImagesTests: XCTestCase {
    private let image = String(TextAroundImages.image)

    func testSplitsTextAroundImages() {
        XCTAssertEqual(TextAroundImages("hi there").runs, ["hi there"])
        XCTAssertEqual(TextAroundImages("look\(image)\nnice right").runs, ["look", "\nnice right"])
        XCTAssertEqual(TextAroundImages("\(image)caption").runs, ["", "caption"])
    }

    func testAnImageOnItsOwnHasNoTextToPolish() {
        XCTAssertFalse(TextAroundImages(image).hasText)
        XCTAssertFalse(TextAroundImages("\(image)\n \(image)").hasText)
        XCTAssertTrue(TextAroundImages("\(image)ok").hasText)
    }

    func testPolishedTextKeepsTheBreaksAgainstTheImages() {
        XCTAssertEqual(TextAroundImages.fitting("Nice, right?\n", into: "\nnice right "), "\nNice, right? ")
        XCTAssertEqual(TextAroundImages.fitting("Done.", into: "done"), "Done.")
    }

    func testWithoutImagesTheWholeTextIsReplaced() {
        XCTAssertEqual(TextAroundImages.edits(from: ["helo"], to: ["Hello."]), [.delete(4), .insert("Hello.")])
    }

    func testImagesAreSteppedOverNotDeleted() {
        let edits = TextAroundImages.edits(from: ["look", "\nnice right"], to: ["Look:", "\nNice, right?"])
        XCTAssertEqual(edits, [
            .delete(11), .insert("\nNice, right?"),
            .move(-14),
            .delete(4), .insert("Look:"),
            .move(14),
        ])
        XCTAssertFalse(edits.contains(.delete(16)))
    }

    func testUnchangedRunsAreLeftAlone() {
        XCTAssertEqual(TextAroundImages.edits(from: ["", "caption"], to: ["", "Caption."]), [
            .delete(7), .insert("Caption."), .move(-9), .move(9),
        ])
    }

    func testMovesCountUTF16Units() {
        XCTAssertEqual(TextAroundImages.edits(from: ["a", "b"], to: ["a", "👍"]).filter { if case .move = $0 { true } else { false } }, [.move(-3), .move(3)])
    }

    /// Plays the edits on a string the way the host applies them.
    func testEditsTurnTheFieldIntoThePolishedVersion() {
        let old = ["look", "\nnice right", " ok"]
        let new = ["Look:", "\nNice, right?", " OK."]
        var field = Array(old.joined(separator: image).utf16)
        var cursor = field.count
        for edit in TextAroundImages.edits(from: old, to: new) {
            switch edit {
            case .delete(let count):
                field.removeSubrange((cursor - count)..<cursor)
                cursor -= count
            case .insert(let text):
                field.insert(contentsOf: text.utf16, at: cursor)
                cursor += text.utf16.count
            case .move(let offset):
                cursor += offset
            }
        }
        XCTAssertEqual(String(decoding: field, as: UTF16.self), new.joined(separator: image))
        XCTAssertEqual(cursor, field.count)
    }
}
