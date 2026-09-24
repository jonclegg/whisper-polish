import SwiftUI

struct RevisionNotesSection: View {
    @Binding var notes: [String]
    @Binding var draft: String
    @FocusState private var draftFocused: Bool
    var isRecording: Bool
    var elapsed: TimeInterval
    var levels: [Float]
    var isTranscribing: Bool
    var transcribingMessage: String
    var canRepolish: Bool
    var onDelete: (Int) -> Void
    var onAddTyped: () -> Void
    var onToggleRecord: () -> Void
    var onRepolish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Notes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Text("Say what to change. Repolish revises this draft.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(notes.enumerated()), id: \.offset) { index, note in
                        HStack(alignment: .top, spacing: 8) {
                            Text(note)
                                .font(.footnote)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                onDelete(index)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove note")
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Or type a note", text: $draft)
                    .font(.footnote)
                    .focused($draftFocused)
                    .submitLabel(.done)
                    .onSubmit(onAddTyped)
                    .disabled(isRecording || isTranscribing)

                if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: onAddTyped) {
                        Image(systemName: "plus")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.polishTeal)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add note")
                }

                Button(action: onToggleRecord) {
                    Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(isRecording ? Color.red : Color.polishTeal)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.polishTealSoft))
                }
                .buttonStyle(.plain)
                .disabled(isTranscribing)
                .accessibilityLabel(isRecording ? "Stop and add note" : "Record a revision note")
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(.systemGroupedBackground)))

            if isRecording {
                VStack(spacing: 8) {
                    Text(timerLabel)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    WaveformView(levels: levels)
                        .frame(height: 36)
                }
            }

            if isTranscribing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(transcribingMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button(action: onRepolish) {
                Text("Repolish")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Capsule().fill(Color.polishTeal))
            }
            .buttonStyle(.plain)
            .disabled(!canRepolish)
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { draftFocused = false }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var timerLabel: String {
        let total = Int(elapsed.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
