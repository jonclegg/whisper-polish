import Foundation

struct PolishResult: Equatable {
    let text: String
    let style: PolishStyle
    let mode: PolishRewriteMode
    let stealth: Bool
    let model: String
}

enum PolishError: LocalizedError, Equatable {
    case missingAPIKey
    case missingVoiceSample
    case emptyResponse
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your OpenRouter API key in Settings first."
        case .missingVoiceSample:
            return "Add a writing sample before using Voice Match."
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

    /// Translation-hop models — deliberately different vendors from each other
    /// and (typically) from the rewrite model.
    static let finnishHopModel = "google/gemini-2.5-flash"
    static let englishHopModel = "mistralai/mistral-small-3.2-24b-instruct"
    static let turkishHopModel = "google/gemini-2.5-flash"

    private let session: URLSession
    private let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func polish(
        text: String,
        style: PolishStyle,
        mode: PolishRewriteMode,
        voiceSample: String = "",
        apiKey: String,
        model: String,
        onProgress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> PolishResult {
        guard !apiKey.isEmpty else { throw PolishError.missingAPIKey }

        // A verbatim style formats without rewriting, so rewrite modes — which
        // are all strategies for rewriting harder — don't apply.
        let mode = style.isVerbatim ? .normal : mode

        let output: String
        switch mode {
        case .normal:
            onProgress("Polishing…")
            output = try await chat(
                messages: Self.normalMessages(text: text, style: style),
                model: model,
                // Verbatim styles are a formatting task, not a creative one —
                // high temperature would invite the rewrites they forbid.
                temperature: style.isVerbatim ? 0.2 : 0.9,
                apiKey: apiKey
            )
        case .voiceMatch:
            let sample = voiceSample.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sample.isEmpty else { throw PolishError.missingVoiceSample }
            onProgress("Matching voice…")
            output = try await chat(
                messages: Self.voiceMatchMessages(text: text, style: style, voiceSample: sample),
                model: model,
                temperature: 0.95,
                apiKey: apiKey
            )
        case .naturalAudit:
            output = try await naturalAuditPipeline(text: text, style: style, apiKey: apiKey, model: model, onProgress: onProgress)
        case .altTranslation:
            output = try await altTranslationPipeline(text: text, style: style, apiKey: apiKey, model: model, onProgress: onProgress)
        case .translationHop:
            output = try await translationHopPipeline(text: text, style: style, apiKey: apiKey, model: model, onProgress: onProgress)
        }
        return PolishResult(
            text: output,
            style: style,
            mode: mode,
            stealth: mode.storesTranslationHopFlag,
            model: model
        )
    }

    // MARK: - Prompts

    private static let antiAIVoiceRules = """
        - Vary sentence length. Use contractions. It's fine to start a sentence with And or But.
        - Do not use em dashes. Use commas, periods, colons, semicolons, or parentheses instead.
        - Avoid tidy AI contrast formulas such as "not X, but Y", "not just X, but Y", and "X, not Y".
        - No AI tells: no "delve", "furthermore", "moreover", "it's worth noting", "I hope this finds you well". No bullet lists unless the content genuinely needs one.
        """

    static func normalMessages(text: String, style: PolishStyle) -> [Message] {
        if style.isVerbatim {
            return verbatimMessages(text: text)
        }
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

    /// The normal prompt tells the model to rewrite; verbatim styles need the
    /// opposite, so they get their own system prompt instead of an
    /// instruction fragment appended to it.
    static func verbatimMessages(text: String) -> [Message] {
        let system = """
        You format rough voice-note transcripts. You do not rewrite them.

        Rules:
        - Keep the speaker's exact wording. Do not rephrase, reorder, shorten, or expand anything.
        - Break the text into paragraphs where the topic shifts. Structure is your only job.
        - Add sentence punctuation and capitalization where the transcript lacks it.
        - Fix only unambiguous mistakes: clear grammar slips and obvious mis-transcriptions. When in doubt, leave it as spoken.
        - Output only the formatted text. No preamble, no explanation, no quotes around it.
        """
        return [
            Message(role: "system", content: system),
            Message(role: "user", content: text),
        ]
    }

    static func voiceMatchMessages(text: String, style: PolishStyle, voiceSample: String) -> [Message] {
        let system = """
        Rewrite the user's rough voice-note transcript so it sounds like the same person who wrote the sample.

        Rules:
        - Mirror the sample's cadence, sentence length, punctuation habits, and level of formality.
        - Preserve the transcript's meaning, specifics, and intent. Never import facts or phrases from the sample.
        - Keep the rewrite natural and direct. Avoid stiff filler such as "delve", "furthermore", "moreover", and "it's worth noting".
        - \(style.instruction)
        - Output only the rewritten text. No preamble, no explanation, no quotes around it.
        """
        return [
            Message(role: "system", content: system),
            Message(role: "user", content: "Writing sample:\n\(voiceSample)\n\nTranscript to rewrite:\n\(text)"),
        ]
    }

    static func naturalAuditMessages(original: String, draft: String, style: PolishStyle) -> [Message] {
        let system = """
        Revise the draft one final time for natural flow.

        Rules:
        - Preserve the original meaning and facts.
        - Remove stiff phrasing, generic transitions, over-polished wording, and unnecessary structure.
        - Keep useful imperfections: contractions, short sentences, plain words, and occasional sentence fragments are fine.
        - \(style.instruction)
        - Output only the revised text. No preamble, no explanation, no quotes around it.
        """
        return [
            Message(role: "system", content: system),
            Message(role: "user", content: "Original transcript:\n\(original)\n\nDraft rewrite:\n\(draft)"),
        ]
    }

    static func chineseRewriteMessages(text: String, style: PolishStyle) -> [Message] {
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

    // MARK: - Pipelines

    private func naturalAuditPipeline(
        text: String,
        style: PolishStyle,
        apiKey: String,
        model: String,
        onProgress: @Sendable (String) -> Void
    ) async throws -> String {
        onProgress("Drafting…")
        let draft = try await chat(
            messages: Self.normalMessages(text: text, style: style),
            model: model,
            temperature: 0.9,
            apiKey: apiKey
        )

        onProgress("Checking flow…")
        return try await chat(
            messages: Self.naturalAuditMessages(original: text, draft: draft, style: style),
            model: model,
            temperature: 0.7,
            apiKey: apiKey
        )
    }

    private func altTranslationPipeline(
        text: String,
        style: PolishStyle,
        apiKey: String,
        model: String,
        onProgress: @Sendable (String) -> Void
    ) async throws -> String {
        onProgress("Step 1 of 3 · rewriting")
        let chinese = try await chat(
            messages: Self.chineseRewriteMessages(text: text, style: style),
            model: model,
            temperature: 1.1,
            apiKey: apiKey
        )

        onProgress("Step 2 of 3 · translating")
        let turkish = try await chat(
            messages: Self.translationMessages(text: chinese, from: "Chinese", to: "Turkish"),
            model: Self.turkishHopModel,
            temperature: 0.2,
            apiKey: apiKey
        )

        onProgress("Step 3 of 3 · translating")
        return try await chat(
            messages: Self.translationMessages(text: turkish, from: "Turkish", to: "English"),
            model: Self.englishHopModel,
            temperature: 0.2,
            apiKey: apiKey
        )
    }

    private func translationHopPipeline(
        text: String,
        style: PolishStyle,
        apiKey: String,
        model: String,
        onProgress: @Sendable (String) -> Void
    ) async throws -> String {
        onProgress("Step 1 of 4 · rewriting")
        var messages = Self.chineseRewriteMessages(text: text, style: style)
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
