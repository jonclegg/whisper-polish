import Foundation

enum PolishError: LocalizedError, Equatable {
    case missingAPIKey
    case emptyResponse
    /// Status only. The response body is never kept: providers echo the
    /// submitted text back in moderation rejections, and this description is
    /// both logged and shown in Settings, so a body here would be a route
    /// from a transcript to the system log and to the screen.
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your Groq API key in Settings."
        case .emptyResponse:
            return "The cleanup model returned nothing."
        case let .http(code):
            return "Groq error \(code). \(Self.hint(forStatus: code))"
        }
    }

    private static func hint(forStatus code: Int) -> String {
        switch code {
        case 401, 403: return "Check that the API key is right."
        case 404: return "Check the model ID."
        case 429: return "Groq is rate limiting this key. Try again in a moment."
        case 500...599: return "Groq is having trouble. Try again in a moment."
        default: return "Check the model ID and the API key."
        }
    }
}

/// Polishes a transcript through Groq, making the same call the Fixit app
/// makes: the style prompt as the system message, the text as the user
/// message, temperature 0.1, and no reasoning settings, so Groq applies the
/// model's default effort exactly as it does for Fixit. The one deliberate
/// difference is `frameTranscript`. The coordinator treats every error here
/// as "insert the raw transcript", so this type is free to throw rather than
/// paper over failures.
final class PolishService: TextCleaning {
    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
        let temperature: Double
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    private let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
    private let session: URLSession
    private let keyProvider: @Sendable () -> String?

    init(
        session: URLSession = .shared,
        keyProvider: @escaping @Sendable () -> String? = { KeychainStore.read() }
    ) {
        self.session = session
        self.keyProvider = keyProvider
    }

    func clean(_ text: String, prompt: String, model: String) async throws -> String {
        guard let key = keyProvider(), !key.isEmpty else {
            // Never log the key. Its presence and length are enough to tell a
            // missing key apart from a malformed one.
            // Verbose, not a failure worth persisting: cleanup is optional and
            // no key is a perfectly ordinary configuration, so logging it at
            // notice level would write a durable timestamped record of every
            // dictation for anyone who simply never wanted cleanup.
            Diagnostics.verbose("groq: no API key found in the keychain")
            throw PolishError.missingAPIKey
        }
        Diagnostics.verbose("groq: requesting \(model), key present (\(key.count) chars)")

        // Delimiters mark the transcript as data, not as further instructions.
        // Without them, models sometimes treat imperative dictation ("write a
        // two-paragraph reply to this") as a task instead of as words to clean:
        // with the Fixit "Sound native" prompt on gpt-oss-120b, unframed
        // commands were carried out 4 times in 12, framed ones never.
        // Framing lives here so custom cleanup prompts get the same protection.
        let messages: [ChatRequest.Message] = [
            .init(role: "system", content: prompt),
            .init(role: "user", content: Self.frameTranscript(text)),
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(model: model, messages: messages, temperature: 0.1))

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PolishError.http(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        let content = Self.unwrap(decoded.choices.first?.message.content ?? "")
        guard !content.isEmpty else { throw PolishError.emptyResponse }
        return content
    }

    /// Wraps the raw transcript so the model sees a clear data boundary.
    /// Content between the tags is the speaker's words only.
    static func frameTranscript(_ text: String) -> String {
        """
        <transcript>
        \(text)
        </transcript>
        """
    }

    /// Models occasionally wrap their answer in quotes or a code fence even
    /// when told not to, and gpt-oss-120b usually hands the `<transcript>`
    /// tags back around its answer (10 times in 12, measured).
    static func unwrap(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.hasPrefix("<transcript>") {
            text = String(text.dropFirst("<transcript>".count))
        }
        if text.hasSuffix("</transcript>") {
            text = String(text.dropLast("</transcript>".count))
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()  // the opening fence, plus any language tag
            if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                lines.removeLast()
            }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast())
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
