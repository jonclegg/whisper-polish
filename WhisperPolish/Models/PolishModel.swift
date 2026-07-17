import Foundation

/// The OpenRouter models a polish can run on. The raw value is the OpenRouter
/// model id sent in the request and stored on the note.
enum PolishModel: String, CaseIterable, Identifiable, Codable {
    case glm52 = "z-ai/glm-5.2"
    case kimiK3 = "moonshotai/kimi-k3"
    case gpt56 = "openai/gpt-5.6-sol"
    case fable5 = "anthropic/claude-fable-5"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .glm52: return "GLM 5.2"
        case .kimiK3: return "Kimi K3"
        case .gpt56: return "GPT-5.6"
        case .fable5: return "Fable 5"
        }
    }

    static let `default`: PolishModel = .glm52

    /// Display name for a stored model id, falling back to the raw id for
    /// models that are no longer in the list.
    static func label(for id: String) -> String {
        PolishModel(rawValue: id)?.displayName ?? id
    }
}
