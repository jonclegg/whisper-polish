import XCTest
@testable import WhisperPolish

final class AppLinksTests: XCTestCase {
    func testReleaseLinksUsePublicHTTPSPages() {
        XCTAssertEqual(AppLinks.marketing.absoluteString, "https://yallware.com/whisper-polish/")
        XCTAssertEqual(AppLinks.privacyPolicy.absoluteString, "https://yallware.com/whisper-polish/privacy/")
        XCTAssertEqual(AppLinks.support.absoluteString, "https://yallware.com/whisper-polish/support/")
        XCTAssertEqual(
            AppLinks.termsOfUse.absoluteString,
            "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"
        )

        for url in [AppLinks.marketing, AppLinks.privacyPolicy, AppLinks.support, AppLinks.termsOfUse] {
            XCTAssertEqual(url.scheme, "https")
        }
    }
}
