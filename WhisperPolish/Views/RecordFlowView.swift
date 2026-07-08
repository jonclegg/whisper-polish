import SwiftUI

/// Owns the record button and the recording experience. Idle, it's a red
/// circle in the nav row of every screen (plus Aa on the list). Tapping it
/// morphs into the full-screen recorder: the red dot travels down into the
/// stop button while the screen blooms in around it — same destination as
/// the old modal recorder, but one continuous gesture instead of a cover.
struct RecordFlow: View {
    var recording: RecordingController
    var showsComposeButton: Bool
    var onCompose: () -> Void
    var onRecorded: (URL, TimeInterval) -> Void

    @Environment(TranscriptionService.self) private var transcription
    @Namespace private var morph

    var body: some View {
        ZStack(alignment: .top) {
            if recording.isActive {
                recordingScreen
            } else {
                idleControls
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: recording.isActive)
    }

    // MARK: - Idle nav-row controls

    private var idleControls: some View {
        HStack(spacing: 10) {
            Spacer()
            if showsComposeButton {
                Button(action: onCompose) {
                    Text("Aa")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color(.secondarySystemGroupedBackground)))
                        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                }
                .accessibilityLabel("New text note")
            }
            Button {
                Task { await recording.begin() }
            } label: {
                ZStack {
                    Circle()
                        .fill(.red)
                        .frame(width: 32, height: 32)
                    Circle()
                        .fill(.white)
                        .frame(width: 11, height: 11)
                }
                .matchedGeometryEffect(id: "recordCore", in: morph)
                .shadow(color: .red.opacity(0.35), radius: 4, y: 1)
            }
            .accessibilityLabel("Record a new note")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    // MARK: - Full-screen recorder

    private var recordingScreen: some View {
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
                .transition(.opacity.combined(with: .scale(scale: 0.94))
                    .animation(.easeOut(duration: 0.25).delay(0.12)))
            } else {
                ProgressView()
            }

            Spacer()

            bottomControls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
                .transition(.opacity.animation(.easeOut(duration: 0.2)))
        )
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
                        .matchedGeometryEffect(id: "recordCore", in: morph)
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
        .padding(.bottom, 30)
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
