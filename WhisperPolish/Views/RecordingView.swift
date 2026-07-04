import SwiftUI
import SwiftData

struct RecordingView: View {
    let onComplete: (Note) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(TranscriptionService.self) private var transcription
    @AppStorage(SettingsKeys.autoCopyTranscript) private var autoCopy = false

    @State private var recorder = AudioRecorder()
    @State private var phase: Phase = .starting
    @State private var errorMessage: String?

    enum Phase {
        case starting
        case recording
    }

    var body: some View {
        VStack {
            HStack {
                Button("Cancel") {
                    recorder.cancel()
                    dismiss()
                }
                .foregroundStyle(.secondary)
                Spacer()
            }
            .padding()

            Spacer()

            switch phase {
            case .starting:
                ProgressView()
            case .recording:
                VStack(spacing: 26) {
                    Text(timerLabel)
                        .font(.system(size: 40, weight: .medium, design: .monospaced))
                    WaveformView(levels: recorder.levels)
                        .frame(height: 60)
                        .padding(.horizontal, 40)
                    Text("Transcribing on-device · Parakeet V3")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if phase == .recording {
                Button(action: stopAndTranscribe) {
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
                .padding(.bottom, 30)
            }
        }
        .background(Color(.systemGroupedBackground))
        .task { await startRecording() }
        .alert("Recording problem", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil; dismiss() } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var timerLabel: String {
        let total = Int(recorder.elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func startRecording() async {
        guard await AudioRecorder.requestPermission() else {
            errorMessage = "Microphone access is off. Enable it in Settings → Privacy → Microphone."
            return
        }
        do {
            try recorder.start()
            phase = .recording
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Stop is instant: the note appears immediately and transcription
    /// finishes in the background (the model warm-up usually beat us here).
    private func stopAndTranscribe() {
        guard let recorded = recorder.stop() else {
            dismiss()
            return
        }
        let note = Note(
            source: .voice,
            originalText: "",
            audioFileName: recorded.url.lastPathComponent,
            duration: recorded.duration
        )
        note.isTranscribing = true
        modelContext.insert(note)
        dismiss()
        onComplete(note)
        Task { @MainActor in
            let text = (try? await transcription.transcribe(url: recorded.url)) ?? ""
            note.originalText = text
            note.isTranscribing = false
            if autoCopy && !text.isEmpty {
                UIPasteboard.general.string = text
            }
        }
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
