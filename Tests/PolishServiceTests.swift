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

    func testMessagesIncludeStyleInstructionAndTranscript() {
        let messages = PolishService.messages(text: "hello world", style: .reddit)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, "system")
        XCTAssertTrue(messages[0].content.contains(PolishStyle.reddit.instruction))
        // Transcript is framed so imperative notes are not read as model tasks.
        XCTAssertEqual(messages[1], PolishService.Message(
            role: "user", content: PolishService.frameTranscript("hello world")))
        XCTAssertTrue(messages[1].content.contains("hello world"))
        XCTAssertTrue(messages[1].content.contains("<transcript>"))
    }

    func testMessagesCarryAntiAIVoiceRules() {
        let messages = PolishService.messages(text: "hello", style: .email)
        XCTAssertTrue(messages[0].content.contains("Do not use em dashes"))
        XCTAssertTrue(messages[0].content.contains("Never invent facts"))
        // Dictation that sounds like a command must still be treated as speech.
        XCTAssertTrue(messages[0].content.contains("not a request for you"))
    }

    func testFrameTranscriptWrapsTheSpeakerWordsInTags() {
        let framed = PolishService.frameTranscript("write a two paragraph reply")
        XCTAssertTrue(framed.hasPrefix("<transcript>\n"))
        XCTAssertTrue(framed.hasSuffix("\n</transcript>"))
        XCTAssertTrue(framed.contains("write a two paragraph reply"))
    }

    // MARK: - Polish

    func testPolishMakesSingleCallAndReturnsContent() async throws {
        MockURLProtocol.responses = [Self.chatBody("Polished output.")]
        let result = try await makeService().polish(
            text: "raw ramble", style: .email, model: .glm52, apiKey: "sk-or-test"
        )
        XCTAssertEqual(result.text, "Polished output.")
        XCTAssertEqual(result.model, PolishModel.glm52.rawValue)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)

        let body = try XCTUnwrap(MockURLProtocol.requestBodies.first)
        XCTAssertEqual(body["model"] as? String, "z-ai/glm-5.2")
        XCTAssertEqual(body["temperature"] as? Double, 0.9)
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["enabled"] as? Bool, false)
        let auth = MockURLProtocol.requests[0].value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(auth, "Bearer sk-or-test")
    }

    func testPolishSendsSelectedModelID() async throws {
        for model in PolishModel.allCases {
            MockURLProtocol.reset()
            MockURLProtocol.responses = [Self.chatBody("ok")]
            let result = try await makeService().polish(
                text: "x", style: .cleanup, model: model, apiKey: "sk-or-test"
            )
            XCTAssertEqual(result.model, model.rawValue)
            let body = try XCTUnwrap(MockURLProtocol.requestBodies.first)
            XCTAssertEqual(body["model"] as? String, model.rawValue)
        }
    }

    func testMissingAPIKeyThrowsBeforeAnyNetworkCall() async {
        do {
            _ = try await makeService().polish(text: "x", style: .email, model: .glm52, apiKey: "")
            XCTFail("Expected missingAPIKey")
        } catch {
            XCTAssertEqual(error as? PolishError, PolishError.missingAPIKey)
        }
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    func testHTTPErrorSurfacesStatusCode() async {
        MockURLProtocol.responses = [.init(status: 401, body: #"{"error":"bad key"}"#)]
        do {
            _ = try await makeService().polish(text: "x", style: .email, model: .glm52, apiKey: "sk-bad")
            XCTFail("Expected http error")
        } catch let PolishError.http(code, _) {
            XCTAssertEqual(code, 401)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEmptyResponseThrows() async {
        MockURLProtocol.responses = [Self.chatBody("   ")]
        do {
            _ = try await makeService().polish(text: "x", style: .email, model: .glm52, apiKey: "sk-or-test")
            XCTFail("Expected emptyResponse")
        } catch {
            XCTAssertEqual(error as? PolishError, PolishError.emptyResponse)
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
