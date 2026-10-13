import XCTest
@testable import WhisperPolish

final class LearnedWordsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "LearnedWordsTests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testTheAppListsWhatTheKeyboardPublished() {
        XCTAssertEqual(LearnedWords.listed(in: defaults), [])
        LearnedWords.publish(["zorbly", "Brexitland", "apptastic"], to: defaults)
        XCTAssertEqual(LearnedWords.listed(in: defaults), ["apptastic", "Brexitland", "zorbly"])
    }

    func testRemovedWordsDisappearBeforeTheKeyboardCatchesUp() {
        LearnedWords.publish(["zorbly", "apptastic"], to: defaults)
        LearnedWords.remove("Zorbly", from: defaults)
        XCTAssertEqual(LearnedWords.listed(in: defaults), ["apptastic"])
        // The keyboard republishes its old list before it has seen the removal.
        LearnedWords.publish(["zorbly", "apptastic"], to: defaults)
        XCTAssertEqual(LearnedWords.listed(in: defaults), ["apptastic"])
    }

    func testTheKeyboardTakesEachRemovalOnce() {
        LearnedWords.remove("zorbly", from: defaults)
        LearnedWords.remove("apptastic", from: defaults)
        XCTAssertEqual(LearnedWords.takeRemovals(from: defaults), ["zorbly", "apptastic"])
        XCTAssertEqual(LearnedWords.takeRemovals(from: defaults), [])
    }
}
