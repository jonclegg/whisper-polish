import XCTest
@testable import DogballWhisper

final class PreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "DogballWhisperTests.Preferences"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultsAreUsableOnFirstLaunch() {
        let prefs = Preferences(defaults: defaults)
        XCTAssertNil(prefs.activeModelID)
        XCTAssertTrue(prefs.cleanupEnabled)
        XCTAssertEqual(prefs.insertionMode, .paste)
        XCTAssertFalse(prefs.hasCompletedOnboarding)
    }

    func testValuesRoundTripThroughDefaults() {
        let prefs = Preferences(defaults: defaults)
        prefs.activeModelID = "parakeet-v3"
        prefs.cleanupEnabled = false
        prefs.insertionMode = .clipboardOnly
        prefs.hasCompletedOnboarding = true

        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.activeModelID, "parakeet-v3")
        XCTAssertFalse(reloaded.cleanupEnabled)
        XCTAssertEqual(reloaded.insertionMode, .clipboardOnly)
        XCTAssertTrue(reloaded.hasCompletedOnboarding)
    }

    func testHotkeyBindingDefaultsToRightOptionAndRoundTrips() {
        let prefs = Preferences(defaults: defaults)
        XCTAssertEqual(prefs.hotkeyBinding, .rightOption)

        prefs.hotkeyBinding = .fn
        XCTAssertEqual(Preferences(defaults: defaults).hotkeyBinding, .fn)
    }

    func testHotkeyBindingFallsBackToRightOptionWhenStoredDataFailsToDecode() {
        let prefs = Preferences(defaults: defaults)
        prefs.hotkeyBindingData = Data("not valid json".utf8)
        XCTAssertEqual(prefs.hotkeyBinding, .rightOption)
    }
}
