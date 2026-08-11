import XCTest
@testable import WhisperPolish

final class CloudPolishServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    private func makeService() -> CloudPolishService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return CloudPolishService(
            endpoint: URL(string: "https://api.example.com/v1/polish")!,
            session: URLSession(configuration: config)
        )
    }

    func testPolishSendsSubscriptionProofAndReturnsUsage() async throws {
        MockURLProtocol.responses = [.init(
            status: 200,
            body: #"{"text":"Finished text","model":"z-ai/glm-5.2","usage":{"used":12,"limit":300,"remaining":288,"resetsAt":"2026-09-01T00:00:00Z"}}"#
        )]

        let result = try await makeService().polish(
            text: "rough words",
            style: .email,
            transactionJWS: "signed-transaction",
            idempotencyKey: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        )

        XCTAssertEqual(result.text, "Finished text")
        XCTAssertEqual(result.model, "z-ai/glm-5.2")
        XCTAssertEqual(result.usage.remaining, 288)
        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer signed-transaction")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Idempotency-Key"),
            "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        )
        let body = try XCTUnwrap(MockURLProtocol.requestBodies.first)
        XCTAssertEqual(body["text"] as? String, "rough words")
        XCTAssertEqual((body["style"] as? [String: Any])?["name"] as? String, "Email")
        XCTAssertEqual(
            (body["style"] as? [String: Any])?["instruction"] as? String,
            PolishStyle.email.instruction
        )
    }

    func testMissingEntitlementFailsWithoutNetworkCall() async {
        do {
            _ = try await makeService().polish(
                text: "rough words",
                style: .email,
                transactionJWS: ""
            )
            XCTFail("Expected missing entitlement")
        } catch {
            XCTAssertEqual(error as? CloudPolishError, .missingEntitlement)
        }
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    func testAllowanceErrorUsesServerMessage() async {
        MockURLProtocol.responses = [.init(
            status: 402,
            body: #"{"error":{"code":"allowance_exhausted","message":"Monthly allowance used."}}"#
        )]

        do {
            _ = try await makeService().polish(
                text: "rough words",
                style: .email,
                transactionJWS: "signed-transaction"
            )
            XCTFail("Expected server error")
        } catch let CloudPolishError.server(status, code, message) {
            XCTAssertEqual(status, 402)
            XCTAssertEqual(code, "allowance_exhausted")
            XCTAssertEqual(message, "Monthly allowance used.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
