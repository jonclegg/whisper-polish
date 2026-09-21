import XCTest
@testable import WhisperPolish

final class PolishSheetChoiceTests: XCTestCase {
    func testQuickCleanupAlwaysRoutesToGroqRegardlessOfCloudAccess() {
        XCTAssertEqual(
            PolishRun.resolve(choice: .quickCleanup, model: .glm52, accessMode: .subscription),
            .quickCleanup
        )
        XCTAssertEqual(
            PolishRun.resolve(choice: .quickCleanup, model: .haiku45, accessMode: .personalKey),
            .quickCleanup
        )
    }

    func testStylePolishStaysOnOpenRouterOrCloud() {
        XCTAssertEqual(
            PolishRun.resolve(choice: .style(.email), model: .kimiK3, accessMode: .personalKey),
            .personalKeyStyle(.email, .kimiK3)
        )
        XCTAssertEqual(
            PolishRun.resolve(choice: .style(.slack), model: .glm52, accessMode: .subscription),
            .cloudStyle(.slack)
        )
    }

    func testQuickCleanupRequiresGroqKeyEvenWhenCloudIsReady() {
        XCTAssertEqual(
            PolishAvailability.of(
                choice: .quickCleanup,
                accessMode: .subscription,
                hasGroqKey: false,
                hasOpenRouterKey: true,
                hasSubscription: true
            ),
            .needsGroqKey
        )
        XCTAssertEqual(
            PolishAvailability.of(
                choice: .quickCleanup,
                accessMode: .personalKey,
                hasGroqKey: true,
                hasOpenRouterKey: false,
                hasSubscription: false
            ),
            .ready
        )
        XCTAssertEqual(
            PolishAvailability.needsGroqKey.message,
            "Add your Groq API key in Settings to use Quick cleanup."
        )
    }

    func testStyleAvailabilityIgnoresGroqKey() {
        XCTAssertEqual(
            PolishAvailability.of(
                choice: .style(.email),
                accessMode: .subscription,
                hasGroqKey: false,
                hasOpenRouterKey: false,
                hasSubscription: true
            ),
            .ready
        )
        XCTAssertEqual(
            PolishAvailability.of(
                choice: .style(.email),
                accessMode: .personalKey,
                hasGroqKey: true,
                hasOpenRouterKey: false,
                hasSubscription: true
            ),
            .needsOpenRouterKey
        )
    }

    func testConfirmTitleIsNotAStyleChipName() {
        XCTAssertEqual(PolishSheetChoice.quickCleanup.confirmTitle, "Quick cleanup")
        XCTAssertEqual(PolishSheetChoice.style(.email).confirmTitle, "Polish as Email")
        XCTAssertFalse(PolishStyle.builtIns.map(\.id).contains(QuickCleanup.id))
        XCTAssertFalse(PolishStyle.builtIns.map(\.name).contains(QuickCleanup.name))
    }
}
