import XCTest
@testable import WhisperPolish

final class PolishProviderTests: XCTestCase {
    func testQuickCleanupUsesLlama3370BVersatile() {
        XCTAssertEqual(QuickCleanup.model, .llama3370bVersatile)
        XCTAssertEqual(QuickCleanup.model.rawValue, "llama-3.3-70b-versatile")
        XCTAssertEqual(QuickCleanup.provider, .groq)
        XCTAssertEqual(PolishModel.llama3370bVersatile.polishProvider, .groq)
        XCTAssertFalse(PolishModel.openRouter.contains(.llama3370bVersatile))
    }

    func testOpenRouterDefaultStaysGLM52() {
        XCTAssertEqual(PolishModel.default, .glm52)
        XCTAssertEqual(PolishModel.resolved(rawValue: PolishModel.llama3370bVersatile.rawValue), .glm52)
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
