import Foundation

/// Storage shared between the app and the keyboard extension.
enum AppGroup {
    static let identifier = Bundle.main.object(forInfoDictionaryKey: "WhisperPolishAppGroup") as! String
    static let defaults = UserDefaults(suiteName: identifier)!

    /// Opened by the keyboard's record button to dictate in the app.
    static let dictationURL = URL(string: "whisperpolish://dictate")!

    /// Style settings lived in standard defaults before the keyboard existed.
    static func migrateStandardDefaults() {
        for key in [SettingsKeys.defaultStyle, SettingsKeys.customStyles] {
            guard defaults.object(forKey: key) == nil,
                  let value = UserDefaults.standard.object(forKey: key) else { continue }
            defaults.set(value, forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
