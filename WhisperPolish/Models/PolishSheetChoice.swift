import Foundation

enum PolishSheetChoice: Equatable {
    case quickCleanup
    case style(PolishStyle)

    var confirmTitle: String {
        switch self {
        case .quickCleanup: return QuickCleanup.name
        case .style(let style): return "Polish as \(style.name)"
        }
    }
}

enum PolishRun: Equatable {
    case quickCleanup
    case personalKeyStyle(PolishStyle, PolishModel)
    case cloudStyle(PolishStyle)

    static func resolve(
        choice: PolishSheetChoice,
        model: PolishModel,
        accessMode: CloudAccessMode
    ) -> PolishRun {
        switch choice {
        case .quickCleanup:
            return .quickCleanup
        case .style(let style):
            switch accessMode {
            case .personalKey:
                return .personalKeyStyle(style, model)
            case .subscription:
                return .cloudStyle(style)
            }
        }
    }
}

enum PolishAvailability: Equatable {
    case ready
    case needsGroqKey
    case needsOpenRouterKey
    case needsSubscription

    static func of(
        choice: PolishSheetChoice,
        accessMode: CloudAccessMode,
        hasGroqKey: Bool,
        hasOpenRouterKey: Bool,
        hasSubscription: Bool
    ) -> PolishAvailability {
        switch choice {
        case .quickCleanup:
            return hasGroqKey ? .ready : .needsGroqKey
        case .style:
            switch accessMode {
            case .personalKey:
                return hasOpenRouterKey ? .ready : .needsOpenRouterKey
            case .subscription:
                return hasSubscription ? .ready : .needsSubscription
            }
        }
    }

    var message: String? {
        switch self {
        case .ready: return nil
        case .needsGroqKey:
            return "Add your Groq API key in Settings to use Quick cleanup."
        case .needsOpenRouterKey:
            return "Add your OpenRouter API key in Settings first."
        case .needsSubscription:
            return "Subscribe to Whisper Polish Cloud in Settings first."
        }
    }
}
