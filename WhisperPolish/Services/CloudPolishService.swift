import Foundation

struct CloudUsage: Decodable, Equatable {
    let used: Int
    let limit: Int
    let remaining: Int
    let resetsAt: Date
}

struct CloudPolishResult: Decodable, Equatable {
    let text: String
    let model: String
    let usage: CloudUsage

    func polishResult(style: PolishStyle) -> PolishResult {
        PolishResult(text: text, style: style, model: model)
    }
}

enum CloudPolishError: LocalizedError, Equatable {
    case missingEntitlement
    case server(Int, String, String)
    case unreadableResponse

    var errorDescription: String? {
        switch self {
        case .missingEntitlement:
            return "A current Whisper Polish Cloud subscription is required."
        case .server(_, _, let message):
            return message
        case .unreadableResponse:
            return "The cloud service returned an unreadable response. Try again."
        }
    }
}

final class CloudPolishService {
    private struct PolishRequest: Encodable {
        struct Style: Encodable {
            let name: String
            let instruction: String
        }

        let text: String
        let style: Style
    }

    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable {
            let code: String
            let message: String
        }
        let error: Detail
    }

    private let endpoint: URL
    private let session: URLSession

    init(endpoint: URL, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    func polish(
        text: String,
        style: PolishStyle,
        transactionJWS: String,
        idempotencyKey: UUID = UUID()
    ) async throws -> CloudPolishResult {
        guard !transactionJWS.isEmpty else { throw CloudPolishError.missingEntitlement }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(transactionJWS)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(idempotencyKey.uuidString, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try JSONEncoder().encode(PolishRequest(
            text: text,
            style: .init(name: style.name, instruction: style.instruction)
        ))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudPolishError.unreadableResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
                throw CloudPolishError.server(
                    http.statusCode,
                    envelope.error.code,
                    envelope.error.message
                )
            }
            throw CloudPolishError.server(
                http.statusCode,
                "http_error",
                "Cloud polish failed (\(http.statusCode))."
            )
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let result = try? decoder.decode(CloudPolishResult.self, from: data) else {
            throw CloudPolishError.unreadableResponse
        }
        return result
    }
}
