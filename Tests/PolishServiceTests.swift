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
        XCTAssertEqual(messages[1], PolishService.Message(role: "user", content: "hello world"))
    }

    func testMessagesCarryAntiAIVoiceRules() {
        let messages = PolishService.messages(text: "hello", style: .email)
        XCTAssertTrue(messages[0].content.contains("Do not use em dashes"))
        XCTAssertTrue(messages[0].content.contains("Never invent facts"))
    }

    // MARK: - Polish

    func testPolishMakesSingleGLMCallAndReturnsContent() async throws {
        MockURLProtocol.responses = [Self.chatBody("Polished output.")]
        let result = try await makeService().polish(
            text: "raw ramble", style: .email, apiKey: "sk-or-test"
        )
        XCTAssertEqual(result.text, "Polished output.")
        XCTAssertEqual(result.model, PolishService.model)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)

        let body = try XCTUnwrap(MockURLProtocol.requestBodies.first)
        XCTAssertEqual(body["model"] as? String, "z-ai/glm-5.2")
        XCTAssertEqual(body["temperature"] as? Double, 0.9)
        let auth = MockURLProtocol.requests[0].value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(auth, "Bearer sk-or-test")
    }

    func testMissingAPIKeyThrowsBeforeAnyNetworkCall() async {
        do {
            _ = try await makeService().polish(text: "x", style: .email, apiKey: "")
            XCTFail("Expected missingAPIKey")
        } catch {
            XCTAssertEqual(error as? PolishError, PolishError.missingAPIKey)
        }
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    func testHTTPErrorSurfacesStatusCode() async {
        MockURLProtocol.responses = [.init(status: 401, body: #"{"error":"bad key"}"#)]
        do {
            _ = try await makeService().polish(text: "x", style: .email, apiKey: "sk-bad")
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
            _ = try await makeService().polish(text: "x", style: .email, apiKey: "sk-or-test")
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
