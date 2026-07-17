import Foundation

struct PolishResult: Equatable {
    let text: String
    let style: PolishStyle
    let model: String
}

enum PolishError: LocalizedError, Equatable {
    case missingAPIKey
    case emptyResponse
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your OpenRouter API key in Settings first."
        case .emptyResponse:
            return "The model returned an empty response. Try again."
        case .http(let code, let body):
            return "OpenRouter error \(code): \(body)"
        }
    }
}

/// Rewrites transcripts so they read like a person wrote them.
final class PolishService {
    struct Message: Codable, Equatable {
        let role: String
        let content: String
    }

    private let session: URLSession
    private let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func polish(text: String, style: PolishStyle, model: PolishModel, apiKey: String) async throws -> PolishResult {
        guard !apiKey.isEmpty else { throw PolishError.missingAPIKey }
        let output = try await chat(
            model: model,
            messages: Self.messages(text: text, style: style),
            temperature: 0.9,
            apiKey: apiKey
        )
        return PolishResult(text: output, style: style, model: model.rawValue)
    }

    // MARK: - Prompt

    private static let antiAIVoiceRules = """
        - Vary sentence length. Use contractions. It's fine to start a sentence with And or But.
        - Do not use em dashes. Use commas, periods, colons, semicolons, or parentheses instead.
        - Avoid tidy AI contrast formulas such as "not X, but Y", "not just X, but Y", and "X, not Y".
        - No AI tells: no "delve", "furthermore", "moreover", "it's worth noting", "I hope this finds you well". No bullet lists unless the content genuinely needs one.
        """

    static func messages(text: String, style: PolishStyle) -> [Message] {
        let system = """
        Rewrite rough voice-note transcripts into finished text that sounds like the speaker, not like AI.

        Rules:
        - Keep the speaker's meaning, specifics, and personality. Never invent facts.
        \(antiAIVoiceRules)
        - Cut filler, false starts, and repetition without flattening the voice.
        - Output only the rewritten text. No preamble, no explanation, no quotes around it.

        \(style.instruction)
        """
        return [
            Message(role: "system", content: system),
            Message(role: "user", content: text),
        ]
    }

    // MARK: - OpenRouter

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
        let temperature: Double
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct ChoiceMessage: Decodable { let content: String? }
            let message: ChoiceMessage
        }
        let choices: [Choice]
    }

    private func chat(model: PolishModel, messages: [Message], temperature: Double, apiKey: String) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ChatRequest(model: model.rawValue, messages: messages, temperature: temperature))

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PolishError.http(http.statusCode, String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw PolishError.emptyResponse
        }
        return content
    }
}
