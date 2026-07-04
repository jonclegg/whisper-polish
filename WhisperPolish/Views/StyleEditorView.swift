import SwiftUI

/// Create or edit a custom polish style. A style is just a name plus the
/// instruction appended to the polish prompt.
struct StyleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKeys.customStyles) private var customStylesJSON = ""

    /// Custom style being edited, or nil to create a new one.
    let editingID: String?
    @State private var name: String
    @State private var instruction: String

    /// Called with the saved style so callers can select it immediately.
    var onSave: ((PolishStyle) -> Void)?

    init(editing style: PolishStyle? = nil, seedInstruction: String = "", onSave: ((PolishStyle) -> Void)? = nil) {
        self.editingID = style?.id
        self.onSave = onSave
        _name = State(initialValue: style?.name ?? "")
        _instruction = State(initialValue: style?.instruction ?? seedInstruction)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Standup update", text: $name)
                }
                Section {
                    TextEditor(text: $instruction)
                        .frame(minHeight: 120)
                } header: {
                    Text("Instruction")
                } footer: {
                    Text("Tell the model how to shape the text, e.g. “Shape it into a daily standup update: past tense, three short bullets, no fluff.”")
                }
            }
            .navigationTitle(editingID == nil ? "New style" : "Edit style")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                                  || instruction.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let style = PolishStyle(
            id: editingID ?? "custom-\(UUID().uuidString)",
            name: name.trimmingCharacters(in: .whitespaces),
            instruction: instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        var custom = PolishStyle.decodeCustom(customStylesJSON)
        if let index = custom.firstIndex(where: { $0.id == style.id }) {
            custom[index] = style
        } else {
            custom.append(style)
        }
        customStylesJSON = PolishStyle.encodeCustom(custom)
        onSave?(style)
        dismiss()
    }
}
