import SwiftUI

extension Color {
    /// Accent for everything Polish-related.
    static let polishTeal = Color(red: 0.06, green: 0.46, blue: 0.43)
    static let polishTealSoft = Color(red: 0.89, green: 0.95, blue: 0.94)
    static let waveGreen = Color(red: 0.20, green: 0.78, blue: 0.35)
}

enum SettingsKeys {
    static let recordOnLaunch = "recordOnLaunch"
    static let autoCopyTranscript = "autoCopyTranscript"
    static let openRouterKey = "openRouterKey"
    static let polishModel = "polishModel"
    static let defaultStyle = "defaultStyle"
    /// JSON-encoded [PolishStyle] of user-created styles.
    static let customStyles = "customStyles"
    static let stealthByDefault = "stealthByDefault"
    static let engine = "transcriptionEngine"
    static let hasCompletedSetup = "hasCompletedSetup"

    static let defaultModel = "openai/gpt-4o"
}
