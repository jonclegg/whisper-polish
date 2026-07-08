import SwiftUI

/// The persistent bottom dock: Aa composer + the big record button, present
/// on every screen. Installed as a `safeAreaInset`, so it's a real section —
/// content ends above it instead of scrolling underneath.
struct RecordDockBar: View {
    /// Top padding + record button + bottom padding. Pushed screens don't
    /// inherit the root's `safeAreaInset`, so they reserve this explicitly.
    static let height: CGFloat = 10 + 66 + 4

    var recording: RecordingController
    var onCompose: () -> Void

    var body: some View {
        HStack(spacing: 22) {
            Button(action: onCompose) {
                Text("Aa")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color(.secondarySystemGroupedBackground)))
                    .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
            }
            .accessibilityLabel("New text note")

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

            // Placeholder to keep the record button centered.
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.top, 10)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGroupedBackground))
        .overlay(alignment: .top) { Divider() }
    }
}

/// Full-screen recorder, zoomed out of the dock's record button (the scale
/// transition in NotesListView anchors at the button) and back into it on
/// stop or cancel.
struct RecordingScreen: View {
    var recording: RecordingController
    var onRecorded: (URL, TimeInterval) -> Void

    @Environment(TranscriptionService.self) private var transcription

    var body: some View {
        VStack {
            Spacer()

            if recording.phase == .recording {
                VStack(spacing: 26) {
                    Text(timerLabel)
                        .font(.system(size: 40, weight: .medium, design: .monospaced))
                    WaveformView(levels: recording.recorder.levels)
                        .frame(height: 60)
                        .padding(.horizontal, 40)
                    Text("Transcribing on-device · \(transcription.selectedEngine.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
            }

            Spacer()

            bottomControls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    private var bottomControls: some View {
        ZStack {
            Button {
                if let recorded = recording.stop() {
                    onRecorded(recorded.url, recorded.duration)
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(Color(.systemBackground))
                        .frame(width: 66, height: 66)
                        .overlay(Circle().stroke(Color(.label), lineWidth: 4))
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.red)
                        .frame(width: 22, height: 22)
                }
            }
            .accessibilityLabel("Stop and save")

            HStack {
                Button {
                    recording.cancel()
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "xmark")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 54, height: 54)
                            .background(Circle().fill(Color(.secondarySystemGroupedBackground)))
                        Text("Cancel")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 44)
        }
        .padding(.bottom, 16)
    }

    private var timerLabel: String {
        let total = Int(recording.recorder.elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

struct WaveformView: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.waveGreen)
                    .frame(width: 4, height: max(6, CGFloat(level) * 56))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.linear(duration: 0.05), value: levels)
    }
}
