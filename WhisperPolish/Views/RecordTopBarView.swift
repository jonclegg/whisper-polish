import SwiftUI

/// The always-present record control, overlaid on the nav-bar row of every
/// screen. Idle, it's a red circle in the top-right (plus Aa on the list).
/// Tapping it morphs the row in place into an inline recorder: the red dot
/// becomes the stop button via matched geometry while cancel, timer, and
/// waveform cascade in — no modal, no layout shift below.
struct RecordTopBar: View {
    var recording: RecordingController
    var showsComposeButton: Bool
    var onCompose: () -> Void
    var onRecorded: (URL, TimeInterval) -> Void

    @Namespace private var morph

    var body: some View {
        ZStack {
            if recording.isActive {
                recordingBar
            } else {
                idleControls
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: recording.isActive)
    }

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
                        .matchedGeometryEffect(id: "recordCore", in: morph)
                    Circle()
                        .fill(.white)
                        .frame(width: 11, height: 11)
                }
                .shadow(color: .red.opacity(0.35), radius: 4, y: 1)
            }
            .accessibilityLabel("Record a new note")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    private var recordingBar: some View {
        HStack(spacing: 10) {
            Button {
                recording.cancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color(.tertiarySystemFill)))
            }
            .accessibilityLabel("Cancel recording")
            .transition(.opacity.combined(with: .move(edge: .trailing))
                .animation(.spring(response: 0.35, dampingFraction: 0.8).delay(0.16)))

            if recording.phase == .recording {
                HStack(spacing: 6) {
                    PulsingDot()
                    Text("New note")
                        .font(.caption2.weight(.bold))
                        .textCase(.uppercase)
                        .foregroundStyle(.red)
                }
                .transition(.opacity.combined(with: .move(edge: .trailing))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8).delay(0.12)))

                Text(timerLabel)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .transition(.opacity.combined(with: .move(edge: .trailing))
                        .animation(.spring(response: 0.35, dampingFraction: 0.8).delay(0.08)))

                WaveformView(
                    levels: Array(recording.recorder.levels.suffix(24)),
                    barWidth: 2.5,
                    spacing: 2,
                    maxHeight: 22,
                    minHeight: 3
                )
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .transition(.opacity
                    .animation(.easeOut(duration: 0.25).delay(0.05)))
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
                        .frame(width: 36, height: 36)
                        .matchedGeometryEffect(id: "recordCore", in: morph)
                    RoundedRectangle(cornerRadius: 3.5)
                        .fill(.white)
                        .frame(width: 12, height: 12)
                }
            }
            .accessibilityLabel("Stop and save")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(
            Color(.systemGroupedBackground)
                .transition(.opacity.animation(.easeOut(duration: 0.15)))
        )
    }

    private var timerLabel: String {
        let total = Int(recording.recorder.elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct PulsingDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 7, height: 7)
            .opacity(pulsing ? 0.25 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever()) {
                    pulsing = true
                }
            }
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
