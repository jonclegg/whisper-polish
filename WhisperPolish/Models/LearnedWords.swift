import Foundation

/// Words the keyboard added to its dictionary on its own, shown in the app so
/// the user can remove them. What the keyboard learned stays in its own
/// container, so the two trade lists through the app group: the keyboard
/// publishes its words, the app queues removals, and the keyboard applies
/// them the next time it opens.
enum LearnedWords {
    /// What the app shows: the keyboard's last published words, less any removals it hasn't applied yet.
    static func listed(in defaults: UserDefaults = AppGroup.defaults) -> [String] {
        let forgotten = Set(pendingRemovals(in: defaults).map { $0.lowercased() })
        return (defaults.stringArray(forKey: SettingsKeys.learnedWords) ?? [])
            .filter { !forgotten.contains($0.lowercased()) }
    }

    /// Called by the keyboard with everything it has learned.
    static func publish(_ words: [String], to defaults: UserDefaults = AppGroup.defaults) {
        let sorted = words.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        defaults.set(sorted, forKey: SettingsKeys.learnedWords)
    }

    /// Called by the app; the keyboard forgets the word next time it opens.
    static func remove(_ word: String, from defaults: UserDefaults = AppGroup.defaults) {
        defaults.set(pendingRemovals(in: defaults) + [word], forKey: SettingsKeys.forgottenWords)
    }

    /// Called by the keyboard: the removals queued since it last looked, which it now owns.
    static func takeRemovals(from defaults: UserDefaults = AppGroup.defaults) -> [String] {
        let removals = pendingRemovals(in: defaults)
        defaults.removeObject(forKey: SettingsKeys.forgottenWords)
        return removals
    }

    private static func pendingRemovals(in defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: SettingsKeys.forgottenWords) ?? []
    }
}
