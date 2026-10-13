import SwiftUI

/// Switches for the keyboard's heavier features; the keyboard picks them up the next time it opens.
struct KeyboardOptionsView: View {
    @State private var options = KeyboardOptions.load()

    var body: some View {
        Form {
            Section {
                ForEach(KeyboardOptions.all, id: \.key) { option in
                    Toggle(isOn: binding(option.key, option.path)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title)
                            Text(option.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("If typing feels slow, turn these off one at a time to find which one does it. Changes apply the next time the keyboard opens.")
            }
        }
        .navigationTitle("Keyboard options")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func binding(_ key: String, _ path: WritableKeyPath<KeyboardOptions, Bool>) -> Binding<Bool> {
        Binding {
            options[keyPath: path]
        } set: { isOn in
            options[keyPath: path] = isOn
            AppGroup.defaults.set(isOn, forKey: key)
        }
    }
}
