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

    // A model ID stored for OpenRouter is a 404 at Groq, so it must not be
    // picked up as the cleanup model.
    func testAModelStoredForOpenRouterIsNotUsedWithGroq() {
        defaults.set("openai/gpt-4.1-nano", forKey: "cleanupModelID")
        XCTAssertEqual(Preferences(defaults: defaults).cleanupModelID, "openai/gpt-oss-120b")
    }

    // Groq stays the default so an existing setup keeps working; S1-mini is
    // opt-in because it needs a download first.
    func testTheCleanupEngineDefaultsToGroqAndPersists() {
        XCTAssertEqual(Preferences(defaults: defaults).cleanupEngine, .groq)
        Preferences(defaults: defaults).cleanupEngine = .s1Mini
        XCTAssertEqual(Preferences(defaults: defaults).cleanupEngine, .s1Mini)
    }

    func testDefaultsAreUsableOnFirstLaunch() {
        let prefs = Preferences(defaults: defaults)
        XCTAssertNil(prefs.activeModelID)
        XCTAssertTrue(prefs.cleanupEnabled)
        XCTAssertEqual(prefs.cleanupModelID, Preferences.defaultCleanupModelID)
        XCTAssertEqual(prefs.cleanupPrompt, Preferences.defaultCleanupPrompt)
        XCTAssertEqual(prefs.insertionMode, .paste)
        XCTAssertFalse(prefs.hasCompletedOnboarding)
    }

    func testValuesRoundTripThroughDefaults() {
        let prefs = Preferences(defaults: defaults)
        prefs.activeModelID = "parakeet-v3"
        prefs.cleanupEnabled = false
        prefs.insertionMode = .clipboardOnly
        prefs.cleanupPrompt = "Strip the ums."
        prefs.hasCompletedOnboarding = true

        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.activeModelID, "parakeet-v3")
        XCTAssertFalse(reloaded.cleanupEnabled)
        XCTAssertEqual(reloaded.insertionMode, .clipboardOnly)
        XCTAssertEqual(reloaded.cleanupPrompt, "Strip the ums.")
        XCTAssertTrue(reloaded.hasCompletedOnboarding)
    }

    func testEmptyCleanupPromptFallsBackToTheDefault() {
        let prefs = Preferences(defaults: defaults)
        prefs.cleanupPrompt = "   "
        XCTAssertEqual(prefs.cleanupPrompt, Preferences.defaultCleanupPrompt)
    }

    func testEmptyCleanupModelIDFallsBackToTheDefault() {
        let prefs = Preferences(defaults: defaults)
        prefs.cleanupModelID = "  "
        XCTAssertEqual(prefs.cleanupModelID, Preferences.defaultCleanupModelID)
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
