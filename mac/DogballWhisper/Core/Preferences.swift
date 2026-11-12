import Foundation

enum InsertionMode: String, Codable {
    case paste
    case clipboardOnly
}

/// Typed wrapper over UserDefaults: everything the user can configure.
final class Preferences {
    private enum Key {
        static let hotkeyBinding = "hotkeyBinding"
        static let activeModelID = "activeModelID"
        static let cleanupEnabled = "cleanupEnabled"
        static let insertionMode = "insertionMode"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.cleanupEnabled: true,
            Key.insertionMode: InsertionMode.paste.rawValue,
        ])
    }

    var activeModelID: String? {
        get { defaults.string(forKey: Key.activeModelID) }
        set { defaults.set(newValue, forKey: Key.activeModelID) }
    }

    var cleanupEnabled: Bool {
        get { defaults.bool(forKey: Key.cleanupEnabled) }
        set { defaults.set(newValue, forKey: Key.cleanupEnabled) }
    }

    var insertionMode: InsertionMode {
        get { InsertionMode(rawValue: defaults.string(forKey: Key.insertionMode) ?? "") ?? .paste }
        set { defaults.set(newValue.rawValue, forKey: Key.insertionMode) }
    }

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Key.hasCompletedOnboarding) }
        set { defaults.set(newValue, forKey: Key.hasCompletedOnboarding) }
    }

    /// Raw storage for the hotkey binding; Task 3 encodes/decodes it.
    var hotkeyBindingData: Data? {
        get { defaults.data(forKey: Key.hotkeyBinding) }
        set { defaults.set(newValue, forKey: Key.hotkeyBinding) }
    }

    var hotkeyBinding: HotkeyBinding {
        get {
            guard let data = hotkeyBindingData,
                  let binding = try? JSONDecoder().decode(HotkeyBinding.self, from: data)
            else { return .rightOption }
            return binding
        }
        set { hotkeyBindingData = try? JSONEncoder().encode(newValue) }
    }
}
