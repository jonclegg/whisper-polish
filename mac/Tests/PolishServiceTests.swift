import XCTest
@testable import DogballWhisper

/// Intercepts URLSession traffic so the tests never hit the network.
final class StubURLProtocol: URLProtocol {
    struct Stub {
        var statusCode = 200
        var body = Data()
        var error: Error?
    }

    nonisolated(unsafe) static var stub = Stub()
    nonisolated(unsafe) static var lastRequestBody: Data?
    nonisolated(unsafe) static var lastRequestURL: URL?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequestURL = request.url
        Self.lastRequestBody = request.httpBody
            ?? request.httpBodyStream.flatMap { stream in
                stream.open()
                var data = Data()
                let size = 4096
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
                defer { buffer.deallocate(); stream.close() }
                while stream.hasBytesAvailable {
                    let read = stream.read(buffer, maxLength: size)
                    if read <= 0 { break }
                    data.append(buffer, count: read)
                }
                return data
            }

        if let error = Self.stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.stub.statusCode,
            httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class PolishServiceTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
        StubURLProtocol.stub = .init()
        StubURLProtocol.lastRequestBody = nil
        StubURLProtocol.lastRequestURL = nil
    }

    private func makeService(key: String? = "sk-test") -> PolishService {
        PolishService(session: session, keyProvider: { key })
    }

    private func chatResponse(_ content: String) -> Data {
        Data(#"{"choices":[{"message":{"content":"\#(content)"}}]}"#.utf8)
    }

    func testReturnsTheCleanedText() async throws {
        StubURLProtocol.stub.body = chatResponse("So the thing is.")
        let result = try await makeService().clean(
            "um so the thing is", prompt: "Clean it.", model: "openai/gpt-oss-120b")
        XCTAssertEqual(result, "So the thing is.")
    }

    // The same request the Fixit app makes, plus the transcript framing.
    func testSendsFixitsRequestShapeToGroq() async throws {
        StubURLProtocol.stub.body = chatResponse("ok")
        _ = try await makeService().clean("raw text", prompt: "MY PROMPT", model: "some/model")

        let body = try XCTUnwrap(StubURLProtocol.lastRequestBody)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "some/model")
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.first?["role"], "system")
        XCTAssertEqual(messages.first?["content"], "MY PROMPT")
        // Transcript is framed so imperative dictation is not read as a task.
        XCTAssertEqual(messages.last?["content"], PolishService.frameTranscript("raw text"))
        XCTAssertTrue(messages.last?["content"]?.contains("raw text") == true)
        XCTAssertTrue(messages.last?["content"]?.contains("<transcript>") == true)
        XCTAssertEqual(json["temperature"] as? Double, 0.1)
        // Fixit sends no reasoning settings, so neither does this.
        XCTAssertEqual(Set(json.keys), ["model", "messages", "temperature"])
    }

    func testTheRequestGoesToGroq() async throws {
        StubURLProtocol.stub.body = chatResponse("ok")
        _ = try await makeService().clean("x", prompt: "p", model: "m")
        XCTAssertEqual(
            StubURLProtocol.lastRequestURL?.absoluteString,
            "https://api.groq.com/openai/v1/chat/completions")
    }

    func testFrameTranscriptWrapsTheSpeakerWordsInTags() {
        let framed = PolishService.frameTranscript("write a two paragraph reply")
        XCTAssertTrue(framed.hasPrefix("<transcript>\n"))
        XCTAssertTrue(framed.hasSuffix("\n</transcript>"))
        XCTAssertTrue(framed.contains("write a two paragraph reply"))
        // The raw words stay intact; only the boundary markers are added.
        XCTAssertEqual(
            framed
                .replacingOccurrences(of: "<transcript>\n", with: "")
                .replacingOccurrences(of: "\n</transcript>", with: ""),
            "write a two paragraph reply")
    }

    func testMissingKeyThrowsBeforeAnyRequest() async {
        do {
            _ = try await makeService(key: nil).clean("x", prompt: "p", model: "m")
            XCTFail("expected missingAPIKey")
        } catch {
            XCTAssertEqual(error as? PolishError, .missingAPIKey)
        }
        XCTAssertNil(StubURLProtocol.lastRequestBody)
    }

    func testHTTPErrorIsReportedWithItsStatusCode() async {
        StubURLProtocol.stub.statusCode = 429
        StubURLProtocol.stub.body = Data(#"{"error":"rate limited"}"#.utf8)
        do {
            _ = try await makeService().clean("x", prompt: "p", model: "m")
            XCTFail("expected http error")
        } catch {
            XCTAssertEqual(error as? PolishError, .http(429))
        }
    }

    func testEmptyContentThrows() async {
        StubURLProtocol.stub.body = chatResponse("   ")
        do {
            _ = try await makeService().clean("x", prompt: "p", model: "m")
            XCTFail("expected emptyResponse")
        } catch {
            XCTAssertEqual(error as? PolishError, .emptyResponse)
        }
    }

    func testMalformedJSONThrows() async {
        StubURLProtocol.stub.body = Data("not json".utf8)
        do {
            _ = try await makeService().clean("x", prompt: "p", model: "m")
            XCTFail("expected a decoding error")
        } catch {
            XCTAssertTrue(error is DecodingError)
        }
    }

    func testTransportErrorPropagates() async {
        StubURLProtocol.stub.error = URLError(.notConnectedToInternet)
        do {
            _ = try await makeService().clean("x", prompt: "p", model: "m")
            XCTFail("expected a URLError")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }

    // Model output sometimes arrives wrapped in quotes or a fenced block.
    func testWrappingQuotesAreStripped() async throws {
        StubURLProtocol.stub.body = chatResponse("\\\"So the thing is.\\\"")
        let quoted = try await makeService().clean("x", prompt: "p", model: "m")
        XCTAssertEqual(quoted, "So the thing is.")
    }

    func testCodeFencesAreStripped() {
        XCTAssertEqual(
            PolishService.unwrap("```\nSo the thing is.\n```"), "So the thing is.")
        XCTAssertEqual(
            PolishService.unwrap("```text\nSo the thing is.\n```"), "So the thing is.")
        // Real content that merely contains backticks must survive untouched.
        XCTAssertEqual(PolishService.unwrap("Use `git status` first."), "Use `git status` first.")
    }

    // Measured on gpt-oss-120b: the framing tags come back around the answer
    // most of the time, and must never be pasted.
    func testEchoedTranscriptTagsAreStripped() {
        XCTAssertEqual(
            PolishService.unwrap("<transcript>\nWrite a reply to Bob.\n</transcript>"),
            "Write a reply to Bob.")
        XCTAssertEqual(
            PolishService.unwrap("<transcript> So the thing is. </transcript>"), "So the thing is.")
        XCTAssertEqual(PolishService.unwrap("So the thing is."), "So the thing is.")
    }

    // Providers echo the submitted text back in moderation rejections, and
    // this description is both logged and shown in Settings > Cleanup > Test,
    // so the response body must not reach it.
    func testAnHTTPErrorKeepsTheStatusButNotTheResponseBody() async throws {
        StubURLProtocol.stub.statusCode = 403
        StubURLProtocol.stub.body = Data(
            #"{"error":{"message":"flagged: so um I was thinking we could ship it"}}"#.utf8)
        do {
            _ = try await makeService().clean("x", prompt: "p", model: "m")
            XCTFail("expected http error")
        } catch {
            XCTAssertEqual(error as? PolishError, .http(403))
            let described = try XCTUnwrap((error as? PolishError)?.errorDescription)
            XCTAssertTrue(described.contains("Groq error 403"))
            XCTAssertFalse(described.contains("ship it"))
        }
    }
}
