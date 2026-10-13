import Foundation

/// Switches for the keyboard's heavier features, set in the app and read by the
/// keyboard each time it opens, so a slow one can be found by turning it off.
struct KeyboardOptions: Equatable {
    /// Suggestion taps go through a UIKit layer like the keys instead of SwiftUI's buttons.
    var barTapLayer = true
    /// Next-word predictions and completions from the word model.
    var predictions = true
    var autocorrect = true
    /// Profile details offered in form fields.
    var autofill = true
    /// Predictions read the whole message, not just the sentence the app shares.
    var wholeMessage = true
    /// A key click when a suggestion is tapped.
    var suggestionClick = true

    static let all: [(key: String, title: String, detail: String, path: WritableKeyPath<KeyboardOptions, Bool>)] = [
        ("keyboardBarTapLayer", "Fast suggestion taps", "Suggestion taps are handled the way key taps are, instead of by SwiftUI.", \.barTapLayer),
        ("keyboardPredictions", "Word predictions", "Suggests next words and completions. Off also turns off autocorrect.", \.predictions),
        ("keyboardAutocorrect", "Autocorrect", "Fixes typos when you press space.", \.autocorrect),
        ("keyboardAutofill", "AutoFill", "Offers your details in form fields.", \.autofill),
        ("keyboardWholeMessage", "Whole-message context", "Predicts from the whole message, not just the current sentence.", \.wholeMessage),
        ("keyboardSuggestionClick", "Click on suggestion taps", "Plays the key click when you tap a suggestion.", \.suggestionClick),
    ]

    static func load(from defaults: UserDefaults = AppGroup.defaults) -> KeyboardOptions {
        var options = KeyboardOptions()
        for option in all {
            options[keyPath: option.path] = defaults.object(forKey: option.key) as? Bool ?? true
        }
        return options
    }
}
