import Foundation

/// Models a personal-key polish can run on. The raw value is the provider
/// model id sent in the request and stored on the note.
enum PolishModel: String, CaseIterable, Identifiable, Codable {
    // OpenRouter · Frontier
    case glm52 = "z-ai/glm-5.2"
    case kimiK3 = "moonshotai/kimi-k3"
    case gpt56 = "openai/gpt-5.6-sol"
    case fable5 = "anthropic/claude-fable-5"
    // OpenRouter · Fast & cheap
    case haiku45 = "anthropic/claude-haiku-4.5"
    case gpt56Luna = "openai/gpt-5.6-luna"
    case gpt41 = "openai/gpt-4.1"
    case gemini35Flash = "google/gemini-3.5-flash"
    case glm5Turbo = "z-ai/glm-5-turbo"
    // Groq
    case gptOss120b = "openai/gpt-oss-120b"
    case gptOss20b = "openai/gpt-oss-20b"

    var id: String { rawValue }

    var polishProvider: PolishProvider {
        switch self {
        case .gptOss120b, .gptOss20b: return .groq
        default: return .openRouter
        }
    }

    var displayName: String {
        switch self {
        case .glm52: return "GLM 5.2"
        case .kimiK3: return "Kimi K3"
        case .gpt56: return "GPT-5.6"
        case .fable5: return "Fable 5"
        case .haiku45: return "Haiku 4.5"
        case .gpt56Luna: return "GPT-5.6 Luna"
        case .gpt41: return "GPT-4.1"
        case .gemini35Flash: return "Gemini 3.5 Flash"
        case .glm5Turbo: return "GLM 5 Turbo"
        case .gptOss120b: return "GPT-OSS 120B"
        case .gptOss20b: return "GPT-OSS 20B"
        }
    }

    var subtitle: String {
        switch self {
        case .glm52: return "Z.AI · the default"
        case .kimiK3: return "Moonshot"
        case .gpt56: return "OpenAI flagship"
        case .fable5: return "Anthropic flagship"
        case .haiku45: return "Anthropic"
        case .gpt56Luna: return "OpenAI"
        case .gpt41: return "OpenAI classic"
        case .gemini35Flash: return "Google"
        case .glm5Turbo: return "Z.AI"
        case .gptOss120b: return "Groq · the default"
        case .gptOss20b: return "Groq · faster"
        }
    }

    static let frontier: [PolishModel] = [.glm52, .kimiK3, .gpt56, .fable5]
    static let fast: [PolishModel] = [.haiku45, .gpt56Luna, .gpt41, .gemini35Flash, .glm5Turbo]
    static let groq: [PolishModel] = [.gptOss120b, .gptOss20b]

    static let `default`: PolishModel = .glm52

    static func models(for provider: PolishProvider) -> [PolishModel] {
        switch provider {
        case .openRouter: return frontier + fast
        case .groq: return groq
        }
    }

    static func `default`(for provider: PolishProvider) -> PolishModel {
        switch provider {
        case .openRouter: return .glm52
        case .groq: return .gptOss120b
        }
    }

    static func resolved(rawValue: String, provider: PolishProvider) -> PolishModel {
        if let model = PolishModel(rawValue: rawValue), model.polishProvider == provider {
            return model
        }
        return `default`(for: provider)
    }

    /// Display name for a stored model id, falling back to the raw id for
    /// models that are no longer in the list.
    static func label(for id: String) -> String {
        PolishModel(rawValue: id)?.displayName ?? id
    }
}
