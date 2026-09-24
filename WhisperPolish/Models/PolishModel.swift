import Foundation

/// OpenRouter `reasoning` object. Nil fields are omitted so a mandatory-reasoning
/// model is not sent `enabled: false`.
struct PolishReasoning: Encodable, Equatable {
    var enabled: Bool? = nil
    var effort: String? = nil
    var exclude: Bool? = nil

    private enum CodingKeys: String, CodingKey {
        case enabled
        case effort
        case exclude
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(enabled, forKey: .enabled)
        try container.encodeIfPresent(effort, forKey: .effort)
        try container.encodeIfPresent(exclude, forKey: .exclude)
    }
}

/// The OpenRouter models a polish can run on. The raw value is the OpenRouter
/// model id sent in the request and stored on the note.
enum PolishModel: String, CaseIterable, Identifiable, Codable {
    // Frontier
    case glm52 = "z-ai/glm-5.2"
    case kimiK3 = "moonshotai/kimi-k3"
    case gpt56 = "openai/gpt-5.6-sol"
    case fable5 = "anthropic/claude-fable-5"
    case opus55 = "anthropic/claude-opus-5.5"
    // Fast & cheap
    case haiku45 = "anthropic/claude-haiku-4.5"
    case gpt56Luna = "openai/gpt-5.6-luna"
    case gpt41 = "openai/gpt-4.1"
    case gemini35Flash = "google/gemini-3.5-flash"
    case glm5Turbo = "z-ai/glm-5-turbo"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .glm52: return "GLM 5.2"
        case .kimiK3: return "Kimi K3"
        case .gpt56: return "GPT-5.6"
        case .fable5: return "Fable 5"
        case .opus55: return "Opus 5.5"
        case .haiku45: return "Haiku 4.5"
        case .gpt56Luna: return "GPT-5.6 Luna"
        case .gpt41: return "GPT-4.1"
        case .gemini35Flash: return "Gemini 3.5 Flash"
        case .glm5Turbo: return "GLM 5 Turbo"
        }
    }

    var subtitle: String {
        switch self {
        case .glm52: return "Z.AI · the default"
        case .kimiK3: return "Moonshot"
        case .gpt56: return "OpenAI flagship"
        case .fable5: return "Anthropic flagship"
        case .opus55: return "Anthropic"
        case .haiku45: return "Anthropic"
        case .gpt56Luna: return "OpenAI"
        case .gpt41: return "OpenAI classic"
        case .gemini35Flash: return "Google"
        case .glm5Turbo: return "Z.AI"
        }
    }

    static let frontier: [PolishModel] = [.glm52, .kimiK3, .gpt56, .fable5, .opus55]
    static let fast: [PolishModel] = [.haiku45, .gpt56Luna, .gpt41, .gemini35Flash, .glm5Turbo]

    static let `default`: PolishModel = .glm52

    /// OpenRouter rejects `enabled: false` when reasoning is mandatory.
    /// Opus 5.5 uses the same payload as Astra: medium effort, trace excluded.
    var reasoning: PolishReasoning {
        switch self {
        case .opus55:
            return PolishReasoning(effort: "medium", exclude: true)
        case .fable5, .gemini35Flash:
            return PolishReasoning(effort: "low", exclude: true)
        case .glm52, .kimiK3, .gpt56, .haiku45, .gpt56Luna, .gpt41, .glm5Turbo:
            return PolishReasoning(enabled: false)
        }
    }

    /// Display name for a stored model id, falling back to the raw id for
    /// models that are no longer in the list.
    static func label(for id: String) -> String {
        PolishModel(rawValue: id)?.displayName ?? id
    }
}
