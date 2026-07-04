import SwiftUI
import SwiftData

struct TextComposerView: View {
    let onSave: (Note) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextEditor(text: $text)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemGroupedBackground)))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("Type or paste the text you want to polish…")
                                .foregroundStyle(.tertiary)
                                .padding(20)
                                .allowsHitTesting(false)
                        }
                    }

                if text.isEmpty, UIPasteboard.general.hasStrings {
                    Button {
                        if let pasted = UIPasteboard.general.string {
                            text = pasted
                        }
                    } label: {
                        Label("Paste from clipboard", systemImage: "doc.on.clipboard")
                            .font(.subheadline.weight(.medium))
                    }
                }
            }
            .padding(14)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("New text note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        let note = Note(source: .text, originalText: text.trimmingCharacters(in: .whitespacesAndNewlines))
                        modelContext.insert(note)
                        dismiss()
                        onSave(note)
                    }
                    .fontWeight(.semibold)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
    }
}
