import SwiftUI
import SwiftData
import AVFoundation

struct NoteDetailView: View {
    @Bindable var note: Note

    @Environment(TranscriptionService.self) private var transcription
    @Environment(DockContext.self) private var dockContext
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
                                Text("Stealth")
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
                .padding(.bottom, 96)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(note.createdAt.formatted(date: .numeric, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: copy) {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .disabled(visibleText.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear(perform: syncDockActions)
        .onChange(of: visibleText) { syncDockActions() }
        .onChange(of: note.isTranscribing) { syncDockActions() }
        .sheet(isPresented: $showPolishSheet) {
            PolishSheetView(hasAPIKey: !apiKey.isEmpty) { style, stealth in
                showPolishSheet = false
                runPolish(style: style, stealth: stealth)
            }
            .presentationDetents([.height(340), .medium, .large])
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
            dockContext.noteActions = nil
        }
    }

    /// Publishes this note's actions into the persistent dock's side slots
    /// (✦ Polish on the left, Share on the right).
    private func syncDockActions() {
        dockContext.noteActions = .init(
            canPolish: !note.originalText.isEmpty && !note.isTranscribing,
            shareText: visibleText,
            requestPolish: { showPolishSheet = true }
        )
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
