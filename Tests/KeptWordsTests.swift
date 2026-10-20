import UIKit
import XCTest

final class KeptWordsTests: XCTestCase {
    func testWordsAreLearnedOnceOthersFollowThem() {
        var kept = KeptWords()
        for word in ["see", "you", "at"] {
            XCTAssertEqual(kept.finished(word, previous: []), [])
            kept.typed(word.count + 1)
        }
        XCTAssertEqual(kept.finished("noon", previous: ["see", "you", "at"]).map(\.text), ["see"])
    }

    func testAWordDeletedBackIntoIsNotLearned() {
        var kept = KeptWords()
        _ = kept.finished("teh", previous: [])
        kept.typed(1)
        kept.deleted(1)
        XCTAssertEqual(kept.held.map(\.text), ["teh"], "Backing up to the word's end keeps it")
        kept.deleted(1)
        XCTAssertEqual(kept.held, [])
    }

    func testDeletesOnlyReachTheWordsTheyCross() {
        var kept = KeptWords()
        _ = kept.finished("meet", previous: [])
        kept.typed(" tomorow".count)
        _ = kept.finished("tomorow", previous: ["meet"])
        kept.typed(1)
        kept.deleted(3)
        XCTAssertEqual(kept.flush().map(\.text), ["meet"])
        XCTAssertEqual(kept.held, [])
    }

    func testAWordEndingBeforeTheCursorCountsTheGap() {
        var kept = KeptWords()
        // A tapped suggestion arrives with its space.
        _ = kept.finished("thanks", previous: [], after: 1)
        kept.deleted(1)
        XCTAssertEqual(kept.held.map(\.text), ["thanks"])
    }

    func testDroppingForgetsEverything() {
        var kept = KeptWords()
        _ = kept.finished("hello", previous: [])
        kept.drop()
        XCTAssertEqual(kept.flush(), [])
    }
}

final class WritingFieldTests: XCTestCase {
    private final class Traits: NSObject, UITextInputTraits {
        var keyboardType: UIKeyboardType = .default
        var returnKeyType: UIReturnKeyType = .default
        var autocorrectionType: UITextAutocorrectionType = .default
        var textContentType: UITextContentType! = nil
        var isSecureTextEntry = false
    }

    private func holdsWriting(_ change: (Traits) -> Void) -> Bool {
        let traits = Traits()
        change(traits)
        return WritingField.holdsWriting(traits)
    }

    func testOrdinaryFieldsHoldWriting() {
        XCTAssertTrue(holdsWriting { _ in })
        XCTAssertTrue(holdsWriting { $0.keyboardType = .twitter })
        XCTAssertTrue(holdsWriting { $0.returnKeyType = .send })
    }

    func testAddressesSearchesAndSecretsDoNot() {
        XCTAssertFalse(holdsWriting { $0.keyboardType = .URL })
        XCTAssertFalse(holdsWriting { $0.keyboardType = .emailAddress })
        XCTAssertFalse(holdsWriting { $0.keyboardType = .webSearch })
        XCTAssertFalse(holdsWriting { $0.returnKeyType = .search })
        XCTAssertFalse(holdsWriting { $0.textContentType = .password })
        XCTAssertFalse(holdsWriting { $0.textContentType = .emailAddress })
        XCTAssertFalse(holdsWriting { $0.isSecureTextEntry = true })
    }

    func testFieldsTheAppKeepsAutocorrectOutOfDoNot() {
        XCTAssertFalse(holdsWriting { $0.autocorrectionType = .no })
    }
}
