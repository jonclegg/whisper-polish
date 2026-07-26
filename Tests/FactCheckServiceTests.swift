import XCTest
@testable import WhisperPolish

final class FactCheckServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    private func makeService() -> FactCheckService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return FactCheckService(session: URLSession(configuration: config))
    }

    // MARK: - Request shape

    func testRequestUsesFixedFrontierModelNotThePolishModel() {
        let body = FactCheckService.requestBody(text: "anything")
        XCTAssertEqual(body["model"] as? String, "anthropic/claude-opus-4.8")
    }

    func testRequestEnablesTheWebSearchServerTool() throws {
        let body = FactCheckService.requestBody(text: "anything")
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["type"] as? String, "openrouter:web_search")

        // The deprecated paths must not be used.
        XCTAssertNil(body["plugins"])
        XCTAssertFalse((body["model"] as? String ?? "").hasSuffix(":online"))
    }

    func testRequestBoundsTheAgentLoop() throws {
        let body = FactCheckService.requestBody(text: "anything")
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        let params = try XCTUnwrap(tools[0]["parameters"] as? [String: Any])
        XCTAssertEqual(params["max_uses"] as? Int, 6)
        // Default is 30 searches per request, which is a runaway bill.
        let maxToolCalls = try XCTUnwrap(body["max_tool_calls"] as? Int)
        XCTAssertLessThanOrEqual(maxToolCalls, 8)
    }

    func testRequestAsksForStrictStructuredOutput() throws {
        let body = FactCheckService.requestBody(text: "anything")
        let format = try XCTUnwrap(body["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let schema = try XCTUnwrap(format["json_schema"] as? [String: Any])
        XCTAssertEqual(schema["strict"] as? Bool, true)

        // And only routes to endpoints that honour it.
        let provider = try XCTUnwrap(body["provider"] as? [String: Any])
        XCTAssertEqual(provider["require_parameters"] as? Bool, true)
    }

    func testRequestCarriesTheTextAndTheFactCheckerPrompt() throws {
        let body = FactCheckService.requestBody(text: "The moon landing was 1968.")
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"], "system")
        XCTAssertTrue(try XCTUnwrap(messages[0]["content"]).contains("fact-checker"))
        XCTAssertEqual(messages[1]["role"], "user")
        XCTAssertEqual(messages[1]["content"], "The moon landing was 1968.")
    }

    func testPromptForbidsInventedSourcesAndAllowsEmptyResults() {
        // Collapse the literal's line wrapping so re-flowing the prompt text
        // doesn't break these assertions.
        let prompt = FactCheckService.systemPrompt
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        XCTAssertTrue(prompt.contains("Never invent, guess, or reconstruct a URL"))
        XCTAssertTrue(prompt.contains("empty findings list, and that is a perfectly good answer"))
    }

    func testCheckSendsAuthHeaderAndOneRequest() async throws {
        MockURLProtocol.responses = [Self.chatBody(#"{"findings":[]}"#)]
        _ = try await makeService().check(text: "hi", apiKey: "sk-or-test")
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        XCTAssertEqual(
            MockURLProtocol.requests[0].value(forHTTPHeaderField: "Authorization"),
            "Bearer sk-or-test"
        )
    }

    // MARK: - Response decoding

    func testCheckDecodesFindings() async throws {
        MockURLProtocol.responses = [Self.chatBody("""
        {"findings":[
          {"claim":"Landing was 1968","verdict":"contradicted","note":"It was 1969.",
           "sources":[{"title":"nasa.gov","url":"https://nasa.gov/apollo-11"}]}
        ]}
        """)]
        let report = try await makeService().check(text: "Landing was 1968", apiKey: "k")
        XCTAssertEqual(report.findings.count, 1)
        XCTAssertEqual(report.findings[0].verdict, .contradicted)
        XCTAssertEqual(report.findings[0].claim, "Landing was 1968")
        XCTAssertEqual(report.findings[0].sources.first?.url, "https://nasa.gov/apollo-11")
        XCTAssertEqual(report.model, FactCheckService.model)
    }

    func testEmptyFindingsIsASuccessNotAnError() async throws {
        MockURLProtocol.responses = [Self.chatBody(#"{"findings":[]}"#)]
        let report = try await makeService().check(text: "I feel tired today.", apiKey: "k")
        XCTAssertTrue(report.findings.isEmpty)
    }

    func testDecodeToleratesMarkdownFencedJSON() throws {
        let findings = try FactCheckService.decodeFindings(from: """
        Here you go:
        ```json
        {"findings":[{"claim":"c","verdict":"supported","note":"n","sources":[]}]}
        ```
        """)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].verdict, .supported)
    }

    func testUnknownVerdictFallsBackToUnverifiableRatherThanFailing() throws {
        let findings = try FactCheckService.decodeFindings(
            from: #"{"findings":[{"claim":"c","verdict":"mostly true","note":"n","sources":[]}]}"#
        )
        XCTAssertEqual(findings[0].verdict, .unverifiable)
    }

    func testMissingOptionalFieldsDecodeToEmpty() throws {
        let findings = try FactCheckService.decodeFindings(
            from: #"{"findings":[{"claim":"c","verdict":"supported"}]}"#
        )
        XCTAssertEqual(findings[0].note, "")
        XCTAssertTrue(findings[0].sources.isEmpty)
    }

    func testNonJSONResponseThrowsUnreadable() async {
        MockURLProtocol.responses = [Self.chatBody("I could not check that, sorry.")]
        do {
            _ = try await makeService().check(text: "hi", apiKey: "k")
            XCTFail("expected an error")
        } catch let error as FactCheckError {
            XCTAssertEqual(error, .unreadableResponse)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Errors

    func testMissingAPIKeyFailsBeforeAnyRequest() async {
        do {
            _ = try await makeService().check(text: "hi", apiKey: "")
            XCTFail("expected an error")
        } catch let error as FactCheckError {
            XCTAssertEqual(error, .missingAPIKey)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    func testHTTPErrorSurfaces() async {
        MockURLProtocol.responses = [.init(status: 401, body: "bad key")]
        do {
            _ = try await makeService().check(text: "hi", apiKey: "k")
            XCTFail("expected an error")
        } catch let error as FactCheckError {
            XCTAssertEqual(error, .http(401, "bad key"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testEmptyContentThrowsEmptyResponse() async {
        MockURLProtocol.responses = [.init(status: 200, body: #"{"choices":[{"message":{"content":""}}]}"#)]
        do {
            _ = try await makeService().check(text: "hi", apiKey: "k")
            XCTFail("expected an error")
        } catch let error as FactCheckError {
            XCTAssertEqual(error, .emptyResponse)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Report ordering

    func testReportPutsProblemsFirst() {
        let report = FactCheckReport(
            findings: [
                .init(claim: "a", verdict: .supported, note: "", sources: []),
                .init(claim: "b", verdict: .unverifiable, note: "", sources: []),
                .init(claim: "c", verdict: .contradicted, note: "", sources: []),
            ],
            model: FactCheckService.model
        )
        XCTAssertEqual(report.sorted.map(\.claim), ["c", "b", "a"])
        XCTAssertEqual(report.contradicted.map(\.claim), ["c"])
    }

    // MARK: - Helpers

    private static func chatBody(_ content: String) -> MockURLProtocol.Response {
        let payload: [String: Any] = ["choices": [["message": ["content": content]]]]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return .init(status: 200, body: String(data: data, encoding: .utf8)!)
    }
}
