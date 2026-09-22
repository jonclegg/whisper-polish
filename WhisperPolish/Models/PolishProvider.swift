import Foundation

/// Where a personal-key request is sent. Cloud subscription polish stays on
/// the Whisper Polish backend. Quick cleanup always uses Groq.
enum PolishProvider: String, CaseIterable, Identifiable, Codable {
    case openRouter
    case groq

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .groq: return "Groq"
        }
    }

    var chatCompletionsURL: URL {
        switch self {
        case .openRouter:
            return URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        case .groq:
            return URL(string: "https://api.groq.com/openai/v1/chat/completions")!
        }
    }

    var includesReasoningField: Bool { self == .openRouter }

    var keyPlaceholder: String {
        switch self {
        case .openRouter: return "OpenRouter API key (sk-or-…)"
        case .groq: return "Groq API key (gsk_…)"
        }
    }

    var keysURL: URL {
        switch self {
        case .openRouter: return URL(string: "https://openrouter.ai/keys")!
        case .groq: return URL(string: "https://console.groq.com/keys")!
        }
    }

    var keysLinkTitle: String {
        switch self {
        case .openRouter: return "Get a key at openrouter.ai/keys"
        case .groq: return "Get a key at console.groq.com/keys"
        }
    }
}
