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
                // Padding must be contentMargins (scroll insets), not outer
                // .padding. Outer padding shrinks the TextEditor frame without
                // growing its scrollable content area, so after pasting a long
                // note you can never scroll the last lines into view.
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .focused($focused)
                        .scrollContentBackground(.hidden)
                        .contentMargins(.horizontal, 12, for: .scrollContent)
                        .contentMargins(.vertical, 12, for: .scrollContent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if text.isEmpty {
                        Text("Type or paste the text you want to polish…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 17)
                            .padding(.vertical, 20)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemGroupedBackground)))
                .clipShape(RoundedRectangle(cornerRadius: 18))

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
            .scrollDismissesKeyboard(.interactively)
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
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = false }
                }
            }
            .onAppear { focused = true }
        }
    }
}
