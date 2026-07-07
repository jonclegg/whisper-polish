import XCTest
@testable import WhisperPolish

final class PolishServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    private func makeService() -> PolishService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return PolishService(session: URLSession(configuration: config))
    }

    // MARK: - Prompt assembly

    func testNormalMessagesIncludeStyleInstructionAndTranscript() {
        let messages = PolishService.normalMessages(text: "hello world", style: .reddit)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, "system")
        XCTAssertTrue(messages[0].content.contains(PolishStyle.reddit.instruction))
        XCTAssertEqual(messages[1], PolishService.Message(role: "user", content: "hello world"))
    }

    func testNormalMessagesBanCommonAIPatterns() {
        let system = PolishService.normalMessages(text: "hello world", style: .cleanup)[0].content
        XCTAssertTrue(system.contains("Do not use em dashes"))
        XCTAssertTrue(system.contains("not X, but Y"))
        XCTAssertTrue(system.contains("not like AI"))
        XCTAssertFalse(system.contains("—"))
    }

    func testTranslationMessagesAreTranslationOnly() {
        let messages = PolishService.translationMessages(text: "moi", from: "Finnish", to: "English")
        XCTAssertTrue(messages[0].content.contains("Finnish"))
        XCTAssertTrue(messages[0].content.contains("English"))
        XCTAssertTrue(messages[0].content.contains("Output only the translation"))
        XCTAssertEqual(messages[1].content, "moi")
    }

    // MARK: - Normal mode

    func testNormalPolishMakesSingleCallAndReturnsContent() async throws {
        MockURLProtocol.responses = [Self.chatBody("Polished output.")]
        let result = try await makeService().polish(
            text: "raw ramble", style: .email, stealth: false, apiKey: "sk-or-test", model: "openai/gpt-4o"
        )
        XCTAssertEqual(result.text, "Polished output.")
        XCTAssertEqual(result.model, "openai/gpt-4o")
        XCTAssertFalse(result.stealth)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)

        let body = try XCTUnwrap(MockURLProtocol.requestBodies.first)
        XCTAssertEqual(body["model"] as? String, "openai/gpt-4o")
        XCTAssertEqual(body["temperature"] as? Double, 0.9)
        let auth = MockURLProtocol.requests[0].value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(auth, "Bearer sk-or-test")
    }

    func testMissingAPIKeyThrowsBeforeAnyNetworkCall() async {
        do {
            _ = try await makeService().polish(
                text: "x", style: .email, stealth: false, apiKey: "", model: "m"
            )
            XCTFail("Expected missingAPIKey")
        } catch {
            XCTAssertEqual(error as? PolishError, PolishError.missingAPIKey)
        }
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    // MARK: - Stealth mode

    func testStealthPipelineChainsFourCallsWithCorrectModels() async throws {
        MockURLProtocol.responses = [
            Self.chatBody("中文改写"),
            Self.chatBody("日本語の書き直し"),
            Self.chatBody("suomenkielinen käännös"),
            Self.chatBody("Final English text."),
        ]
        let result = try await makeService().polish(
            text: "raw ramble", style: .reddit, stealth: true, apiKey: "sk-or-test", model: "openai/gpt-4o"
        )
        XCTAssertEqual(result.text, "Final English text.")
        XCTAssertTrue(result.stealth)
        XCTAssertEqual(MockURLProtocol.requests.count, 4)

        let bodies = MockURLProtocol.requestBodies
        // Rewrites use the configured model at high temperature.
        XCTAssertEqual(bodies[0]["model"] as? String, "openai/gpt-4o")
        XCTAssertEqual(bodies[0]["temperature"] as? Double, 1.3)
        XCTAssertEqual(bodies[1]["model"] as? String, "openai/gpt-4o")
        // Step 2 carries step 1's output as history.
        let step2Messages = bodies[1]["messages"] as? [[String: String]] ?? []
        XCTAssertTrue(step2Messages.contains { $0["role"] == "assistant" && $0["content"] == "中文改写" })
        // Translation hops use the dedicated hop models at low temperature.
        XCTAssertEqual(bodies[2]["model"] as? String, PolishService.finnishHopModel)
        XCTAssertEqual(bodies[3]["model"] as? String, PolishService.englishHopModel)
        XCTAssertEqual(bodies[3]["temperature"] as? Double, 0.2)
        // Final hop translates step 3's output.
        let step4Messages = bodies[3]["messages"] as? [[String: String]] ?? []
        XCTAssertEqual(step4Messages.last?["content"], "suomenkielinen käännös")
    }

    func testStealthFinalEnglishHopIncludesAntiAIGuidance() async throws {
        MockURLProtocol.responses = [
            Self.chatBody("中文改写"),
            Self.chatBody("日本語の書き直し"),
            Self.chatBody("suomenkielinen käännös"),
            Self.chatBody("Final English text."),
        ]

        _ = try await makeService().polish(
            text: "raw ramble", style: .cleanup, stealth: true, apiKey: "sk-or-test", model: "openai/gpt-4o"
        )

        let finalMessages = MockURLProtocol.requestBodies[3]["messages"] as? [[String: String]] ?? []
        let finalSystem = try XCTUnwrap(finalMessages.first?["content"])
        XCTAssertTrue(finalSystem.contains("not like AI"))
        XCTAssertTrue(finalSystem.contains("Do not use em dashes"))
        XCTAssertTrue(finalSystem.contains("not X, but Y"))
        XCTAssertTrue(finalSystem.contains(PolishStyle.cleanup.instruction))
        XCTAssertFalse(finalSystem.contains("—"))
    }

    func testHTTPErrorSurfacesStatusCode() async {
        MockURLProtocol.responses = [.init(status: 401, body: #"{"error":"bad key"}"#)]
        do {
            _ = try await makeService().polish(
                text: "x", style: .email, stealth: false, apiKey: "sk-bad", model: "m"
            )
            XCTFail("Expected http error")
        } catch let PolishError.http(code, _) {
            XCTAssertEqual(code, 401)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private static func chatBody(_ content: String) -> MockURLProtocol.Response {
        let json: [String: Any] = ["choices": [["message": ["content": content]]]]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return .init(status: 200, body: String(data: data, encoding: .utf8)!)
    }
}

// MARK: - URLProtocol mock

final class MockURLProtocol: URLProtocol {
    struct Response {
        let status: Int
        let body: String
    }

    nonisolated(unsafe) static var responses: [Response] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var requestBodies: [[String: Any]] = []

    static func reset() {
        responses = []
        requests = []
        requestBodies = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                Self.requestBodies.append(json)
            }
        }

        let response = Self.responses.isEmpty ? Response(status: 500, body: "no mock response") : Self.responses.removeFirst()
        let httpResponse = HTTPURLResponse(
            url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body.data(using: .utf8)!)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
