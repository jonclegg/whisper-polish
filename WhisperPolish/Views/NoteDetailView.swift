import SwiftUI
import SwiftData
import AVFoundation

struct NoteDetailView: View {
    @Bindable var note: Note

    @Environment(TranscriptionService.self) private var transcription
    @Environment(OpenRouterKeyStore.self) private var openRouterKey
    @Environment(SubscriptionStore.self) private var subscription
    @AppStorage(SettingsKeys.cloudAccessMode) private var cloudAccessRaw = CloudAccessMode.personalKey.rawValue
    @AppStorage(SettingsKeys.defaultStyle) private var defaultStyleRaw = PolishStyle.email.id
    @AppStorage(SettingsKeys.polishModel) private var modelRaw = PolishModel.default.rawValue

    @State private var showingPolished = false
    @State private var showPolishSheet = false
    /// Shared by polish and fact-check: only one model call runs at a time.
    @State private var progressMessage: String?
    @State private var modelTask: Task<Void, Never>?
    @State private var factCheckReport: FactCheckReport?
    @State private var errorTitle = "Polish failed"
    @State private var errorMessage: String?
    @State private var copied = false
    @State private var retrying = false
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false

    private let polishService = PolishService()
    private let factCheckService = FactCheckService()

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
                            if let model = note.polishModel {
                                Text(PolishModel.label(for: model))
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
            PolishSheetView(
                accessMode: cloudAccessMode,
                hasAPIKey: !openRouterKey.value.isEmpty,
                hasSubscription: subscription.isSubscribed
            ) { style, model in
                showPolishSheet = false
                runPolish(style: style, model: model)
            }
            .presentationDetents([.height(400), .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $factCheckReport) { report in
            FactCheckReportView(report: report)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .overlay {
            if let progressMessage {
                progressOverlay(progressMessage)
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
        .alert(errorTitle, isPresented: .init(
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

            Button(action: runFactCheck) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.seal")
                    Text("Check")
                }
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

    private func progressOverlay(_ message: String) -> some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Cancel", role: .cancel) {
                    cancelModelTask()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.polishTeal)
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

    private func runPolish(style: PolishStyle, model: PolishModel) {
        defaultStyleRaw = style.id
        if cloudAccessMode == .personalKey {
            modelRaw = model.rawValue
        }
        run("Polishing…", errorTitle: "Polish failed") {
            switch cloudAccessMode {
            case .personalKey:
                let result = try await polishService.polish(
                    text: note.originalText,
                    style: style,
                    model: model,
                    apiKey: openRouterKey.value
                )
                note.applyPolish(result)
            case .subscription:
                guard let endpoint = AppConfiguration.cloudPolishEndpoint else {
                    throw CloudConfigurationError.missingEndpoint
                }
                let cloud = try await CloudPolishService(endpoint: endpoint).polish(
                    text: note.originalText,
                    style: style,
                    transactionJWS: subscription.entitlementJWS ?? ""
                )
                subscription.record(cloud.usage)
                note.applyPolish(cloud.polishResult(style: style))
            }
            showingPolished = true
        }
    }

    private func runFactCheck() {
        guard !openRouterKey.value.isEmpty else {
            errorTitle = "Personal Key required"
            errorMessage = "Fact checking is not included in the cloud plan yet. Add an OpenRouter key in Settings to use it."
            return
        }
        // Checks whichever version you're reading, so the report always matches
        // the text on screen.
        let text = visibleText
        // Web search across several claims takes a while; the cancel button in
        // the overlay is the escape hatch.
        run("Checking facts…", errorTitle: "Fact check failed") {
            factCheckReport = try await factCheckService.check(text: text, apiKey: openRouterKey.value)
        }
    }

    private var cloudAccessMode: CloudAccessMode {
        CloudAccessMode(rawValue: cloudAccessRaw) ?? .personalKey
    }

    /// Runs one cancellable model call behind the progress overlay.
    private func run(_ message: String, errorTitle title: String, work: @MainActor @escaping () async throws -> Void) {
        progressMessage = message
        modelTask = Task {
            do {
                try await work()
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                errorTitle = title
                errorMessage = error.localizedDescription
            }
            // A cancelled task's state was already cleared by cancelModelTask;
            // clearing here would clobber a run started after the cancel.
            if !Task.isCancelled {
                progressMessage = nil
                modelTask = nil
            }
        }
    }

    private func cancelModelTask() {
        modelTask?.cancel()
        modelTask = nil
        progressMessage = nil
    }
}
