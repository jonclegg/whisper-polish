import XCTest
@testable import WhisperPolish

final class PolishProviderTests: XCTestCase {
    func testGroqDefaultModelIsFixitOSS120B() {
        XCTAssertEqual(PolishModel.default(for: .groq), .gptOss120b)
        XCTAssertEqual(PolishModel.gptOss120b.rawValue, "openai/gpt-oss-120b")
        XCTAssertEqual(PolishModel.models(for: .groq), [.gptOss120b, .gptOss20b])
    }

    func testOpenRouterDefaultStaysGLM52() {
        XCTAssertEqual(PolishModel.default(for: .openRouter), .glm52)
        XCTAssertEqual(PolishModel.default, .glm52)
        XCTAssertFalse(PolishModel.models(for: .openRouter).contains(.gptOss120b))
    }

    func testResolvedModelSwitchesToProviderDefaultWhenMismatched() {
        XCTAssertEqual(
            PolishModel.resolved(rawValue: PolishModel.glm52.rawValue, provider: .groq),
            .gptOss120b
        )
        XCTAssertEqual(
            PolishModel.resolved(rawValue: PolishModel.gptOss120b.rawValue, provider: .openRouter),
            .glm52
        )
        XCTAssertEqual(
            PolishModel.resolved(rawValue: PolishModel.gptOss20b.rawValue, provider: .groq),
            .gptOss20b
        )
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
