import Foundation

struct PolishResult: Equatable {
    let text: String
    let style: PolishStyle
    let stealth: Bool
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
///
/// Normal mode is a single high-temperature chat call with a humanize prompt.
/// Stealth mode ports lynote-ai/humanize-text: two creative LLM rewrites
/// (Chinese, then Japanese with the first as history) followed by two
/// translation hops (Japanese→Finnish, Finnish→English) on different models,
/// so no single model's fingerprint survives.
final class PolishService {
    struct Message: Codable, Equatable {
        let role: String
        let content: String
    }

    /// Translation-hop models — deliberately different vendors from each other
    /// and (typically) from the rewrite model.
    static let finnishHopModel = "google/gemini-2.5-flash"
    static let englishHopModel = "mistralai/mistral-small-3.2-24b-instruct"

    private let session: URLSession
    private let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func polish(
        text: String,
        style: PolishStyle,
        stealth: Bool,
        apiKey: String,
        model: String,
        onProgress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> PolishResult {
        guard !apiKey.isEmpty else { throw PolishError.missingAPIKey }

        let output: String
        if stealth {
            output = try await stealthPipeline(text: text, style: style, apiKey: apiKey, model: model, onProgress: onProgress)
        } else {
            onProgress("Polishing…")
            output = try await chat(
                messages: Self.normalMessages(text: text, style: style),
                model: model,
                temperature: 0.9,
                apiKey: apiKey
            )
        }
        return PolishResult(text: output, style: style, stealth: stealth, model: model)
    }

    // MARK: - Prompts

    private static let antiAIVoiceRules = """
        - Vary sentence length. Use contractions. It's fine to start a sentence with And or But.
        - Do not use em dashes. Use commas, periods, colons, semicolons, or parentheses instead.
        - Avoid tidy AI contrast formulas such as "not X, but Y", "not just X, but Y", and "X, not Y".
        - No AI tells: no "delve", "furthermore", "moreover", "it's worth noting", "I hope this finds you well". No bullet lists unless the content genuinely needs one.
        """

    static func normalMessages(text: String, style: PolishStyle) -> [Message] {
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

    static func finalEnglishMessages(text: String, from source: String, style: PolishStyle) -> [Message] {
        let system = """
        Translate the \(source) text into natural English, then lightly revise it so it sounds like the same person wrote it, not like AI.

        Rules:
        - Keep every fact, detail, paragraph break, and the speaker's intent. Never invent facts.
        - Preserve the selected style, but do not make the result sound generically polished.
        \(antiAIVoiceRules)
        - Output only the final English text. No preamble, no explanation, no quotes around it.

        \(style.instruction)
        """
        return [
            Message(role: "system", content: system),
            Message(role: "user", content: text),
        ]
    }

    static func stealthStep1Messages(text: String, style: PolishStyle) -> [Message] {
        let system = """
        Creatively rewrite the user's text in natural Chinese. Preserve every fact and detail, but restructure sentences freely and improve the flow. \(style.instruction) Output only the Chinese rewrite.
        """
        return [
            Message(role: "system", content: system),
            Message(role: "user", content: text),
        ]
    }

    static func translationMessages(text: String, from source: String, to target: String) -> [Message] {
        [
            Message(role: "system", content: "Translate the \(source) text to natural \(target). Preserve formatting and paragraph breaks. Output only the translation."),
            Message(role: "user", content: text),
        ]
    }

    // MARK: - Stealth pipeline

    private func stealthPipeline(
        text: String,
        style: PolishStyle,
        apiKey: String,
        model: String,
        onProgress: @Sendable (String) -> Void
    ) async throws -> String {
        onProgress("Step 1 of 4 · rewriting")
        var messages = Self.stealthStep1Messages(text: text, style: style)
        let chinese = try await chat(messages: messages, model: model, temperature: 1.3, apiKey: apiKey)

        onProgress("Step 2 of 4 · rewriting")
        messages.append(Message(role: "assistant", content: chinese))
        messages.append(Message(role: "user", content: "Now creatively rewrite that in natural Japanese. Same rules: keep every fact, restructure freely. Output only the Japanese rewrite."))
        let japanese = try await chat(messages: messages, model: model, temperature: 1.3, apiKey: apiKey)

        onProgress("Step 3 of 4 · translating")
        let finnish = try await chat(
            messages: Self.translationMessages(text: japanese, from: "Japanese", to: "Finnish"),
            model: Self.finnishHopModel,
            temperature: 0.2,
            apiKey: apiKey
        )

        onProgress("Step 4 of 4 · translating")
        return try await chat(
            messages: Self.finalEnglishMessages(text: finnish, from: "Finnish", style: style),
            model: Self.englishHopModel,
            temperature: 0.2,
            apiKey: apiKey
        )
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

    private func chat(messages: [Message], model: String, temperature: Double, apiKey: String) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ChatRequest(model: model, messages: messages, temperature: temperature))

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
