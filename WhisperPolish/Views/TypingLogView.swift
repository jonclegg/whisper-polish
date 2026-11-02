import SwiftUI

/// How the suggestion bar did on what the user typed, from the keyboard's typing log,
/// with the log to share for a closer look or to clear.
struct TypingLogView: View {
    @State private var entries = TypingLog.entries()
    @State private var isOn = KeyboardOptions.load().typingLog
    @State private var confirmingClear = false

    var body: some View {
        Form {
            Section {
                Toggle("Typing log", isOn: $isOn)
                    .onChange(of: isOn) { _, isOn in
                        AppGroup.defaults.set(isOn, forKey: KeyboardOptions.typingLogKey)
                    }
            } footer: {
                Text("While this is on, the keyboard notes what the suggestion bar offered and the words you typed, in apps where you write. Passwords, addresses, and search fields are left out. The log stays on this phone until you share it. Needs Allow Full Access.")
            }

            if !entries.isEmpty {
                let summary = TypingLog.summary(of: entries)
                Section("So far") {
                    LabeledContent("Words", value: summary.words.formatted())
                    LabeledContent("Next word offered before typing", value: summary.offeredBeforeTyping.formatted(.percent.precision(.fractionLength(1))))
                    LabeledContent("Keystrokes saved", value: summary.keystrokesSaved.formatted(.percent.precision(.fractionLength(1))))
                    LabeledContent("Suggestions tapped", value: summary.tapped.formatted())
                    LabeledContent("Autocorrections", value: summary.autocorrected.formatted())
                    LabeledContent("Autocorrections undone", value: summary.reverted.formatted())
                }
                Section {
                    ShareLink(item: TypingLog.fileURL) {
                        Label("Share typing log", systemImage: "square.and.arrow.up")
                    }
                    Button("Clear typing log", role: .destructive) {
                        confirmingClear = true
                    }
                    .confirmationDialog("Clear the typing log?", isPresented: $confirmingClear, titleVisibility: .visible) {
                        Button("Clear", role: .destructive) {
                            TypingLog.clear()
                            entries = []
                        }
                    }
                }
            }
        }
        .navigationTitle("Typing log")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { entries = TypingLog.entries() }
    }
}
