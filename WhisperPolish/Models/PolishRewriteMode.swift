import Foundation

enum PolishRewriteMode: String, CaseIterable, Identifiable {
    case normal
    case voiceMatch
    case naturalAudit
    case altTranslation
    case translationHop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: return "Normal"
        case .voiceMatch: return "Voice Match"
        case .naturalAudit: return "Natural Audit"
        case .altTranslation: return "Alt Translation"
        case .translationHop: return "Translation Hop"
        }
    }

    var subtitle: String {
        switch self {
        case .normal:
            return "Single model rewrite. Fastest."
        case .voiceMatch:
            return "Uses a writing sample to mirror cadence."
        case .naturalAudit:
            return "Second pass for stiff phrasing."
        case .altTranslation:
            return "Different cross-language route."
        case .translationHop:
            return "Current four-step chain."
        }
    }

    var badge: String? {
        switch self {
        case .normal:
            return nil
        case .voiceMatch:
            return "Sample"
        case .naturalAudit:
            return "2 pass"
        case .altTranslation:
            return "Route"
        case .translationHop:
            return "4 steps"
        }
    }

    var storesTranslationHopFlag: Bool { self == .translationHop }
}
