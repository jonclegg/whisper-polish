import XCTest
@testable import WhisperPolish

@MainActor
final class SubscriptionStoreTests: XCTestCase {
    func testScreenshotModeProvidesAnActiveRepresentativeSubscription() {
        let store = SubscriptionStore(screenshotMode: true)

        XCTAssertTrue(store.isSubscribed)
        XCTAssertEqual(store.priceText, "$4.99")
        XCTAssertEqual(store.usage?.used, 13)
        XCTAssertEqual(store.usage?.remaining, 287)
        XCTAssertEqual(store.usage?.limit, 300)
    }
}
