import SwiftUI
import SwiftData

struct TextComposerView: View {
    let onSave: (Note) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var text = ""
    @State private var image: UIImage?
    @State private var saving = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canPaste: Bool {
        (image == nil && UIPasteboard.general.hasImages) || (text.isEmpty && UIPasteboard.general.hasStrings)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    if let image {
                        ImageAttachment(image: image) { self.image = nil }
                            .padding(.horizontal, 16)
                            .padding(.top, 16)
                    }
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
                            Text(image == nil
                                 ? "Type or paste the text you want to polish…"
                                 : "Add your text, or save to polish the text in the image…")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 17)
                                .padding(.vertical, 20)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemGroupedBackground)))
                .clipShape(RoundedRectangle(cornerRadius: 18))

                if canPaste {
                    Button(action: paste) {
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
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save", action: save)
                            .fontWeight(.semibold)
                            .disabled(trimmedText.isEmpty && image == nil)
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = false }
                }
            }
            .alert("Couldn't save", isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear { focused = true }
        }
    }

    /// An image wins over text: a copied image often carries its URL as text too.
    private func paste() {
        let pasteboard = UIPasteboard.general
        if image == nil, pasteboard.hasImages, let pasted = pasteboard.image {
            image = pasted
        } else if text.isEmpty, let pasted = pasteboard.string {
            text = pasted
        }
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do {
                let note = try await makeNote()
                modelContext.insert(note)
                dismiss()
                onSave(note)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// With text of its own, the note keeps the image's text as context.
    /// With only an image, the image's text is the note.
    private func makeNote() async throws -> Note {
        let typed = trimmedText
        guard let image else { return Note(source: .text, originalText: typed) }
        let imageText = try await NoteImages.recognizeText(in: image)
        guard !typed.isEmpty || !imageText.isEmpty else { throw ComposerError.noTextInImage }
        let note = Note(source: .text, originalText: typed.isEmpty ? imageText : typed)
        note.imageFileName = try NoteImages.save(image)
        note.imageText = typed.isEmpty || imageText.isEmpty ? nil : imageText
        return note
    }
}

private enum ComposerError: LocalizedError {
    case noTextInImage

    var errorDescription: String? {
        "There's no text in this image. Add the text you want to polish."
    }
}

/// A pasted image's thumbnail with a button to remove it.
private struct ImageAttachment: View {
    let image: UIImage
    let onRemove: () -> Void

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.separator), lineWidth: 0.5))
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(.regularMaterial))
                        .overlay(Circle().stroke(Color(.separator), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .offset(x: 8, y: -8)
                .accessibilityLabel("Remove image")
            }
            .accessibilityLabel("Pasted image")
    }
}
