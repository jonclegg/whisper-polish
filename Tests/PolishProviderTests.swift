import XCTest
@testable import WhisperPolish

final class PolishProviderTests: XCTestCase {
    func testQuickCleanupUsesGroqOSS120B() {
        XCTAssertEqual(QuickCleanup.model, .gptOss120b)
        XCTAssertEqual(QuickCleanup.model.rawValue, "openai/gpt-oss-120b")
        XCTAssertEqual(QuickCleanup.provider, .groq)
        XCTAssertEqual(PolishModel.gptOss120b.polishProvider, .groq)
        XCTAssertFalse(PolishModel.openRouter.contains(.gptOss120b))
    }

    func testOpenRouterDefaultStaysGLM52() {
        XCTAssertEqual(PolishModel.default, .glm52)
        XCTAssertEqual(PolishModel.resolved(rawValue: PolishModel.gptOss120b.rawValue), .glm52)
        XCTAssertEqual(PolishModel.resolved(rawValue: PolishModel.haiku45.rawValue), .haiku45)
    }

    func testEndpointsAndReasoningQuirk() {
        XCTAssertEqual(
            PolishProvider.openRouter.chatCompletionsURL.absoluteString,
            "https://openrouter.ai/api/v1/chat/completions"
        )
        XCTAssertEqual(
            PolishProvider.groq.chatCompletionsURL.absoluteString,
            "https://api.groq.com/openai/v1/chat/completions"
        )
        XCTAssertTrue(PolishProvider.openRouter.includesReasoningField)
        XCTAssertFalse(PolishProvider.groq.includesReasoningField)
    }
}
