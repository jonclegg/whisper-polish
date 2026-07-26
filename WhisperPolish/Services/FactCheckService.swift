import Foundation

enum FactCheckError: LocalizedError, Equatable {
    case missingAPIKey
    case emptyResponse
    case unreadableResponse
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your OpenRouter API key in Settings first."
        case .emptyResponse:
            return "The model returned an empty response. Try again."
        case .unreadableResponse:
            return "The model's answer wasn't in the expected format. Try again."
        case .http(let code, let body):
            return "OpenRouter error \(code): \(body)"
        }
    }
}

/// Checks the factual claims in a note against the live web.
///
/// Deliberately not wired to `PolishModel`: fact-checking is a different job
/// from rewriting, and letting the cheap models do it would produce bad checks
/// that look exactly like good ones.
final class FactCheckService {
    /// Frontier model with native web search and structured-output support.
    static let model = "anthropic/claude-opus-4.8"

    static func displayName(for id: String) -> String {
        id == model ? "Claude Opus 4.8" : id
    }

    private let session: URLSession
    private let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func check(text: String, apiKey: String) async throws -> FactCheckReport {
        guard !apiKey.isEmpty else { throw FactCheckError.missingAPIKey }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.requestBody(text: text))

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FactCheckError.http(http.statusCode, String(data: data.prefix(300), encoding: .utf8) ?? "")
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw FactCheckError.emptyResponse
        }
        return FactCheckReport(findings: try Self.decodeFindings(from: content), model: Self.model)
    }

    // MARK: - Prompt

    static let systemPrompt = """
        You are a fact-checker. The user will give you a piece of writing. Find the
        specific factual claims in it and check each one against the live web.

        How to work:
        - Search the web before judging any claim that isn't universally known. Do not
          rely on memory for anything datable, numeric, attributed, or recent.
        - Only report claims that are actually checkable. Skip opinions, predictions,
          intentions, hypotheticals, jokes, and the writer's own first-person
          experiences. A note with nothing checkable in it should produce an empty
          findings list, and that is a perfectly good answer.
        - Quote each claim as it appears in the text, trimmed to the relevant clause.

        Verdicts:
        - "supported": the sources agree with the claim.
        - "contradicted": the sources disagree with the claim, or it is wrong.
        - "unverifiable": you searched and could not settle it. Use this freely rather
          than guessing. A confident wrong verdict is worse than an honest shrug.

        For each finding write a "note" of at most two plain sentences saying what you
        found. Give the correct figure or fact when you have one.

        Only list a URL in "sources" if you actually retrieved it via search. Never
        invent, guess, or reconstruct a URL. An empty sources list is fine.

        Do not rewrite, improve, or comment on the writing itself. Return only the
        structured result.
        """

    static func requestBody(text: String) -> [String: Any] {
        [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text],
            ],
            // Server tool, not the deprecated `web` plugin or `:online` suffix.
            // The plugin searches exactly once; a note with several claims in it
            // needs the model to search per-claim, which only the tool allows.
            "tools": [
                [
                    "type": "openrouter:web_search",
                    "parameters": ["max_results": 5, "max_uses": 6],
                ]
            ],
            // Bounds the agent loop. Default is 30, which is a runaway bill.
            "max_tool_calls": 8,
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "fact_check", "strict": true, "schema": responseSchema],
            ],
            // Only route to endpoints that actually honour tools + json_schema.
            "provider": ["require_parameters": true],
        ]
    }

    static let responseSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["findings"],
        "properties": [
            "findings": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["claim", "verdict", "note", "sources"],
                    "properties": [
                        "claim": ["type": "string"],
                        "verdict": ["type": "string", "enum": ["supported", "contradicted", "unverifiable"]],
                        "note": ["type": "string"],
                        "sources": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "additionalProperties": false,
                                "required": ["title", "url"],
                                "properties": [
                                    "title": ["type": "string"],
                                    "url": ["type": "string"],
                                ],
                            ],
                        ],
                    ],
                ],
            ]
        ],
    ]

    // MARK: - Response

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct ChoiceMessage: Decodable { let content: String? }
            let message: ChoiceMessage
        }
        let choices: [Choice]
    }

    private struct FindingsEnvelope: Decodable {
        let findings: [FactCheckFinding]
    }

    /// OpenRouter's structured-output support is per-endpoint, and combining
    /// `json_schema` with a server tool isn't documented as guaranteed. So we
    /// ask for strict JSON but still cope with a model that wraps it in prose
    /// or a markdown fence.
    static func decodeFindings(from content: String) throws -> [FactCheckFinding] {
        guard let json = extractJSONObject(from: content),
              let data = json.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(FindingsEnvelope.self, from: data) else {
            throw FactCheckError.unreadableResponse
        }
        return envelope.findings
    }

    private static func extractJSONObject(from content: String) -> String? {
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}"),
              start < end else { return nil }
        return String(content[start...end])
    }
}
