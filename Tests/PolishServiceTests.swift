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

    // Formatting must not inherit the rewrite prompt — its whole contract is
    // that the wording survives untouched.
    func testVerbatimMessagesForbidRewriting() {
        let messages = PolishService.verbatimMessages(text: "hello world")
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages[0].content.contains("You do not rewrite them"))
        XCTAssertTrue(messages[0].content.contains("Keep the speaker's exact wording"))
        XCTAssertEqual(messages[1], PolishService.Message(role: "user", content: "hello world"))
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
            text: "raw ramble", style: .email, mode: .normal, apiKey: "sk-or-test", model: "openai/gpt-4o"
        )
        XCTAssertEqual(result.text, "Polished output.")
        XCTAssertEqual(result.model, "openai/gpt-4o")
        XCTAssertEqual(result.mode, .normal)
        XCTAssertFalse(result.stealth)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)

        let body = try XCTUnwrap(MockURLProtocol.requestBodies.first)
        XCTAssertEqual(body["model"] as? String, "openai/gpt-4o")
        XCTAssertEqual(body["temperature"] as? Double, 0.9)
        let auth = MockURLProtocol.requests[0].value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(auth, "Bearer sk-or-test")
    }

    // Formatting is a single low-temperature call on the verbatim prompt; the
    // selected style plays no part.
    func testFormattingModeMakesSingleVerbatimLowTemperatureCall() async throws {
        MockURLProtocol.responses = [Self.chatBody("Formatted output.")]
        let result = try await makeService().polish(
            text: "raw ramble", style: .email, mode: .formatting, apiKey: "sk-or-test", model: "openai/gpt-4o"
        )
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        XCTAssertEqual(result.mode, .formatting)
        XCTAssertFalse(result.stealth)
        let body = try XCTUnwrap(MockURLProtocol.requestBodies.first)
        XCTAssertEqual(body["temperature"] as? Double, 0.2)
        let messages = body["messages"] as? [[String: String]] ?? []
        XCTAssertTrue(messages.first?["content"]?.contains("You do not rewrite them") ?? false)
        XCTAssertFalse(messages.first?["content"]?.contains(PolishStyle.email.instruction) ?? true)
    }

    func testMissingAPIKeyThrowsBeforeAnyNetworkCall() async {
        do {
            _ = try await makeService().polish(
                text: "x", style: .email, mode: .normal, apiKey: "", model: "m"
            )
            XCTFail("Expected missingAPIKey")
        } catch {
            XCTAssertEqual(error as? PolishError, PolishError.missingAPIKey)
        }
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    // MARK: - Voice Match

    func testVoiceMatchUsesWritingSampleInSingleCall() async throws {
        MockURLProtocol.responses = [Self.chatBody("Voice matched output.")]
        let result = try await makeService().polish(
            text: "raw ramble",
            style: .email,
            mode: .voiceMatch,
            voiceSample: "I usually write short direct updates.",
            apiKey: "sk-or-test",
            model: "openai/gpt-4o"
        )
        XCTAssertEqual(result.text, "Voice matched output.")
        XCTAssertEqual(result.mode, .voiceMatch)
        XCTAssertFalse(result.stealth)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)

        let body = try XCTUnwrap(MockURLProtocol.requestBodies.first)
        XCTAssertEqual(body["temperature"] as? Double, 0.95)
        let messages = body["messages"] as? [[String: String]] ?? []
        XCTAssertTrue(messages.last?["content"]?.contains("Writing sample:") == true)
        XCTAssertTrue(messages.last?["content"]?.contains("I usually write short direct updates.") == true)
    }

    func testVoiceMatchRequiresWritingSampleBeforeAnyNetworkCall() async {
        do {
            _ = try await makeService().polish(
                text: "x", style: .email, mode: .voiceMatch, voiceSample: "   ", apiKey: "sk-or-test", model: "m"
            )
            XCTFail("Expected missingVoiceSample")
        } catch {
            XCTAssertEqual(error as? PolishError, PolishError.missingVoiceSample)
        }
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    // MARK: - Natural Audit

    func testNaturalAuditRunsDraftThenAuditPass() async throws {
        MockURLProtocol.responses = [
            Self.chatBody("Draft output."),
            Self.chatBody("Audited output."),
        ]
        let result = try await makeService().polish(
            text: "raw ramble", style: .reddit, mode: .naturalAudit, apiKey: "sk-or-test", model: "openai/gpt-4o"
        )
        XCTAssertEqual(result.text, "Audited output.")
        XCTAssertEqual(result.mode, .naturalAudit)
        XCTAssertFalse(result.stealth)
        XCTAssertEqual(MockURLProtocol.requests.count, 2)

        let bodies = MockURLProtocol.requestBodies
        XCTAssertEqual(bodies[0]["temperature"] as? Double, 0.9)
        XCTAssertEqual(bodies[1]["temperature"] as? Double, 0.7)
        let auditMessages = bodies[1]["messages"] as? [[String: String]] ?? []
        XCTAssertTrue(auditMessages.last?["content"]?.contains("Draft output.") == true)
        XCTAssertTrue(auditMessages.last?["content"]?.contains("raw ramble") == true)
    }

    // MARK: - Alt Translation

    func testAltTranslationRunsChineseTurkishEnglishRoute() async throws {
        MockURLProtocol.responses = [
            Self.chatBody("中文改写"),
            Self.chatBody("Türkçe çeviri"),
            Self.chatBody("Final English text."),
        ]
        let result = try await makeService().polish(
            text: "raw ramble", style: .email, mode: .altTranslation, apiKey: "sk-or-test", model: "openai/gpt-4o"
        )
        XCTAssertEqual(result.text, "Final English text.")
        XCTAssertEqual(result.mode, .altTranslation)
        XCTAssertFalse(result.stealth)
        XCTAssertEqual(MockURLProtocol.requests.count, 3)

        let bodies = MockURLProtocol.requestBodies
        XCTAssertEqual(bodies[0]["model"] as? String, "openai/gpt-4o")
        XCTAssertEqual(bodies[0]["temperature"] as? Double, 1.1)
        XCTAssertEqual(bodies[1]["model"] as? String, PolishService.turkishHopModel)
        XCTAssertEqual(bodies[2]["model"] as? String, PolishService.englishHopModel)
        let step3Messages = bodies[2]["messages"] as? [[String: String]] ?? []
        XCTAssertEqual(step3Messages.last?["content"], "Türkçe çeviri")
    }

    // MARK: - Translation Hop

    func testTranslationHopPipelineChainsFourCallsWithCorrectModels() async throws {
        MockURLProtocol.responses = [
            Self.chatBody("中文改写"),
            Self.chatBody("日本語の書き直し"),
            Self.chatBody("suomenkielinen käännös"),
            Self.chatBody("Final English text."),
        ]
        let result = try await makeService().polish(
            text: "raw ramble", style: .reddit, mode: .translationHop, apiKey: "sk-or-test", model: "openai/gpt-4o"
        )
        XCTAssertEqual(result.text, "Final English text.")
        XCTAssertEqual(result.mode, .translationHop)
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

    func testHTTPErrorSurfacesStatusCode() async {
        MockURLProtocol.responses = [.init(status: 401, body: #"{"error":"bad key"}"#)]
        do {
            _ = try await makeService().polish(
                text: "x", style: .email, mode: .normal, apiKey: "sk-bad", model: "m"
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
