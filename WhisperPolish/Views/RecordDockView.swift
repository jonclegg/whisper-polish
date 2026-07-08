import SwiftUI

/// Contextual actions the current screen contributes to the persistent dock.
/// The record button never moves; the side slots adapt to where you are.
/// `NoteDetailView` registers its actions here on appear and clears them on
/// disappear; when empty, the dock shows the notes-list slots (Aa composer).
@Observable
final class DockContext {
    struct NoteActions {
        var canPolish: Bool
        var shareText: String
        var requestPolish: () -> Void
    }

    var noteActions: NoteActions?
}

/// The persistent bottom dock, overlaid on the root NavigationStack so it is
/// present on every screen. Idle it shows [contextual · record · contextual];
/// while recording it morphs in place into a pill with timer, live waveform,
/// cancel, and stop — no full-screen takeover.
struct RecordDock: View {
    var recording: RecordingController
    var context: DockContext
    var onCompose: () -> Void
    var onRecorded: (URL, TimeInterval) -> Void

    var body: some View {
        ZStack {
            if recording.isActive {
                RecordingPill(recording: recording, onRecorded: onRecorded)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            } else {
                idleDock
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: recording.isActive)
    }

    private var idleDock: some View {
        HStack(spacing: 0) {
            leadingSlot
                .frame(maxWidth: .infinity, alignment: .leading)
            recordButton
            trailingSlot
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 12)
    }

    private var recordButton: some View {
        Button {
            Task { await recording.begin() }
        } label: {
            Circle()
                .fill(Color(.label))
                .frame(width: 66, height: 66)
                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 4))
                .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        }
        .accessibilityLabel("Record a new note")
    }

    @ViewBuilder
    private var leadingSlot: some View {
        if let actions = context.noteActions {
            Button(action: actions.requestPolish) {
                Image(systemName: "sparkle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(actions.canPolish ? Color.polishTeal : Color(.tertiaryLabel))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color(.secondarySystemGroupedBackground)))
                    .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
            }
            .disabled(!actions.canPolish)
            .accessibilityLabel("Polish this note")
        } else {
            Button(action: onCompose) {
                Text("Aa")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color(.secondarySystemGroupedBackground)))
                    .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
            }
            .accessibilityLabel("New text note")
        }
    }

    @ViewBuilder
    private var trailingSlot: some View {
        if let actions = context.noteActions {
            ShareLink(item: actions.shareText) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color(.secondarySystemGroupedBackground)))
                    .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
            }
            .disabled(actions.shareText.isEmpty)
        } else {
            Color.clear.frame(width: 44, height: 44)
        }
    }
}

private struct RecordingPill: View {
    var recording: RecordingController
    var onRecorded: (URL, TimeInterval) -> Void

    @State private var pulsing = false

    var body: some View {
        VStack(spacing: 8) {
            targetLabel
            pill
        }
        .padding(.bottom, 8)
    }

    /// Always says what the recording lands in, so tapping record mid-edit
    /// is never ambiguous: it's a new note, every time.
    private var targetLabel: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(.red)
                .frame(width: 6, height: 6)
                .opacity(pulsing ? 0.25 : 1)
            Text("Recording · New note")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.red)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color(.secondarySystemGroupedBackground)))
        .shadow(color: .black.opacity(0.1), radius: 4, y: 1)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever()) {
                pulsing = true
            }
        }
    }

    private var pill: some View {
        HStack(spacing: 10) {
            Button {
                recording.cancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color(.tertiarySystemFill)))
            }
            .accessibilityLabel("Cancel recording")

            if recording.phase == .recording {
                Text(timerLabel)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .frame(minWidth: 44, alignment: .leading)
                WaveformView(
                    levels: recording.recorder.levels,
                    barWidth: 2.5,
                    spacing: 2,
                    maxHeight: 24,
                    minHeight: 3
                )
                .frame(maxWidth: .infinity)
                .frame(height: 28)
            } else {
                Spacer()
                ProgressView()
                Spacer()
            }

            Button {
                if let recorded = recording.stop() {
                    onRecorded(recorded.url, recorded.duration)
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(.red)
                        .frame(width: 44, height: 44)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.white)
                        .frame(width: 15, height: 15)
                }
            }
            .accessibilityLabel("Stop and save")
        }
        .padding(8)
        .background(Capsule().fill(Color(.secondarySystemGroupedBackground)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(.horizontal, 16)
    }

    private var timerLabel: String {
        let total = Int(recording.recorder.elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct WaveformView: View {
    let levels: [Float]
    var barWidth: CGFloat = 4
    var spacing: CGFloat = 3
    var maxHeight: CGFloat = 56
    var minHeight: CGFloat = 6

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.waveGreen)
                    .frame(width: barWidth, height: max(minHeight, CGFloat(level) * maxHeight))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.linear(duration: 0.05), value: levels)
    }
}
