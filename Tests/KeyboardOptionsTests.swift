import XCTest
@testable import WhisperPolish

final class KeyboardOptionsTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "KeyboardOptionsTests")!
        defaults.removePersistentDomain(forName: "KeyboardOptionsTests")
    }

    /// Haptics stay off until turned on; everything else starts on.
    func testUnsetOptionsTakeTheirDefaults() {
        let options = KeyboardOptions.load(from: defaults)
        XCTAssertFalse(options.haptics)
        XCTAssertTrue(options.predictions)
        XCTAssertTrue(options.autocorrect)
        XCTAssertTrue(options.emojiAutoReplace)
    }

    func testSavedChoicesWin() {
        defaults.set(true, forKey: "keyboardHaptics")
        defaults.set(false, forKey: "keyboardAutocorrect")
        let options = KeyboardOptions.load(from: defaults)
        XCTAssertTrue(options.haptics)
        XCTAssertFalse(options.autocorrect)
    }
}
