import SwiftUI
import SwiftData
import AVFoundation

struct NoteDetailView: View {
    @Bindable var note: Note

    @Environment(TranscriptionService.self) private var transcription
    @AppStorage(SettingsKeys.openRouterKey) private var apiKey = ""
    @AppStorage(SettingsKeys.polishModel) private var model = SettingsKeys.defaultModel
    @AppStorage(SettingsKeys.defaultStyle) private var defaultStyleRaw = PolishStyle.email.id
    @AppStorage(SettingsKeys.stealthByDefault) private var stealthByDefault = false

    @State private var showingPolished = false
    @State private var showPolishSheet = false
    @State private var polishProgress: String?
    @State private var errorMessage: String?
    @State private var copied = false
    @State private var retrying = false
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false

    private let polishService = PolishService()

    private var visibleText: String {
        showingPolished ? (note.polishedText ?? "") : note.originalText
    }

    var body: some View {
        VStack(spacing: 0) {
            if note.isPolished {
                Picker("Version", selection: $showingPolished) {
                    Text("Original").tag(false)
                    Text("Polished").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 6)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if showingPolished, let styleLabel = note.polishStyleLabel {
                        HStack(spacing: 6) {
                            Label(styleLabel, systemImage: "sparkle")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.polishTeal)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.polishTealSoft))
                            if note.polishStealth {
                                Text("Translation Hop")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.purple)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(.purple.opacity(0.12)))
                            }
                            if let model = note.polishModel {
                                Text(model)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    if note.isTranscribing {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text(transcription.state.transcribingStatusMessage)
                                .foregroundStyle(.secondary)
                        }
                    } else if note.originalText.isEmpty && !showingPolished {
                        emptyTranscript
                    } else {
                        Text(visibleText)
                            .font(.body)
                            .textSelection(.enabled)
                    }

                    if note.source == .voice, !showingPolished, note.audioURL != nil {
                        Button(action: togglePlayback) {
                            HStack(spacing: 6) {
                                Image(systemName: "waveform")
                                    .foregroundStyle(Color.waveGreen)
                                Text("\(note.durationLabel ?? "") · \(isPlaying ? "Stop" : "Play")")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 6)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemGroupedBackground)))
                .padding(14)
            }

            actionBar
        }
        // The root list gets this clearance from the dock's safeAreaInset,
        // but pushed screens don't inherit it.
        .padding(.bottom, RecordDockBar.height)
        .background(Color(.systemGroupedBackground))
        .navigationTitle(note.createdAt.formatted(date: .numeric, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPolishSheet) {
            PolishSheetView(hasAPIKey: !apiKey.isEmpty) { style, stealth in
                showPolishSheet = false
                runPolish(style: style, stealth: stealth)
            }
            .presentationDetents([.height(620), .large])
            .presentationDragIndicator(.visible)
        }
        .overlay {
            if let polishProgress {
                polishingOverlay(polishProgress)
            }
        }
        .overlay(alignment: .bottom) {
            if copied {
                Text("Copied to clipboard")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color(.label)))
                    .padding(.bottom, 90)
                    .transition(.opacity)
            }
        }
        .alert("Polish failed", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onDisappear {
            player?.stop()
        }
    }

    private var emptyTranscript: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No text detected.")
                .foregroundStyle(.secondary)
            if note.audioURL != nil {
                Button {
                    retryTranscription()
                } label: {
                    Label(retrying ? "Transcribing…" : "Retry transcription", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.medium))
                }
                .disabled(retrying)
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button(action: copy) {
                Text("Copy")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Capsule().fill(Color(.secondarySystemGroupedBackground)))
            }
            .buttonStyle(.plain)

            Button {
                showPolishSheet = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "sparkle")
                        .foregroundStyle(Color.polishTealSoft)
                    Text(note.isPolished ? "Re-polish" : "Polish")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Capsule().fill(Color(.label)))
            }
            .buttonStyle(.plain)
            .disabled(note.originalText.isEmpty)

            ShareLink(item: visibleText) {
                Text("Share")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Capsule().fill(Color(.secondarySystemGroupedBackground)))
            }
            .buttonStyle(.plain)
            .disabled(visibleText.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private func polishingOverlay(_ message: String) -> some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .background(RoundedRectangle(cornerRadius: 20).fill(.regularMaterial))
        }
    }

    private func copy() {
        UIPasteboard.general.string = visibleText
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { copied = false }
        }
    }

    private func togglePlayback() {
        if isPlaying {
            player?.stop()
            isPlaying = false
            return
        }
        guard let url = note.audioURL else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            player = try AVAudioPlayer(contentsOf: url)
            player?.play()
            isPlaying = true
            Task {
                while player?.isPlaying == true {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                isPlaying = false
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func retryTranscription() {
        guard let url = note.audioURL else { return }
        retrying = true
        Task {
            defer { retrying = false }
            do {
                note.originalText = try await transcription.transcribe(url: url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func runPolish(style: PolishStyle, stealth: Bool) {
        defaultStyleRaw = style.id
        polishProgress = stealth ? "Starting…" : "Polishing…"
        Task {
            do {
                let result = try await polishService.polish(
                    text: note.originalText,
                    style: style,
                    stealth: stealth,
                    apiKey: apiKey,
                    model: model,
                    onProgress: { progress in
                        Task { @MainActor in polishProgress = progress }
                    }
                )
                note.applyPolish(result)
                showingPolished = true
            } catch {
                errorMessage = error.localizedDescription
            }
            polishProgress = nil
        }
    }
}
