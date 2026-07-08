import SwiftUI
import SwiftData

struct NotesListView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(TranscriptionService.self) private var transcription
    @Query(sort: \Note.createdAt, order: .reverse) private var notes: [Note]

    @AppStorage(SettingsKeys.recordOnLaunch) private var recordOnLaunch = false
    @AppStorage(SettingsKeys.hasCompletedSetup) private var hasCompletedSetup = false
    @AppStorage(SettingsKeys.autoCopyTranscript) private var autoCopy = false
    @State private var path: [Note] = []
    @State private var searchText = ""
    @State private var recording = RecordingController()
    @State private var showComposer = false
    @State private var showSettings = false
    @State private var didRunStartupWork = false
    @State private var launchRecordingGate = LaunchRecordingGate()
    @State private var showModelBanner = false

    /// True while the selected engine is downloading or being optimized.
    private var isPreparingModel: Bool {
        transcription.state == .loading || transcription.state.isDownloading
    }

    private var filteredNotes: [Note] {
        guard !searchText.isEmpty else { return notes }
        return notes.filter {
            $0.originalText.localizedCaseInsensitiveContains(searchText)
                || ($0.polishedText?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if showModelBanner {
                        modelBanner
                    }
                    if notes.isEmpty {
                        emptyState
                    }
                    ForEach(filteredNotes) { note in
                        Button {
                            path.append(note)
                        } label: {
                            NoteCard(note: note)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) { delete(note) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Whisper Polish")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Note.self) { note in
                NoteDetailView(note: note)
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            RecordTopBar(
                recording: recording,
                showsComposeButton: path.isEmpty,
                onCompose: { showComposer = true },
                onRecorded: handleRecorded
            )
        }
        .alert("Recording problem", isPresented: .init(
            get: { recording.errorMessage != nil },
            set: { if !$0 { recording.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(recording.errorMessage ?? "")
        }
        .sheet(isPresented: $showComposer) {
            TextComposerView { note in
                path.append(note)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .fullScreenCover(isPresented: .init(
            get: { !hasCompletedSetup },
            set: { _ in }
        ), onDismiss: handleAppReady) {
            OnboardingView()
        }
        .task { handleAppReady() }
        // Delay so the banner never flashes during a normal fast launch;
        // it only appears when the model is genuinely taking a while.
        .task(id: isPreparingModel) {
            guard isPreparingModel else {
                showModelBanner = false
                return
            }
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled {
                withAnimation { showModelBanner = true }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                launchRecordingGate.appBecameActive()
                handleAppReady()
            case .inactive, .background:
                launchRecordingGate.appMovedAway()
            @unknown default:
                break
            }
        }
    }

    private var modelBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                if case .downloading(let fraction) = transcription.state {
                    Text(fraction.map { "Downloading transcription model… \(Int($0 * 100))%" }
                        ?? "Downloading transcription model…")
                        .font(.footnote.weight(.semibold))
                } else {
                    Text("Optimizing transcription model for this iPhone")
                        .font(.footnote.weight(.semibold))
                    Text("One-time after app updates — keep the app open. You can record now; transcripts appear once it's done.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Tap the red button up top to capture a voice note,\nor Aa to paste text.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 120)
    }

    /// Stop is instant: the note appears immediately and transcription
    /// finishes in the background (the model warm-up usually beat us here).
    private func handleRecorded(url: URL, duration: TimeInterval) {
        let note = Note(
            source: .voice,
            originalText: "",
            audioFileName: url.lastPathComponent,
            duration: duration
        )
        note.isTranscribing = true
        modelContext.insert(note)
        path.append(note)
        Task { @MainActor in
            let text = (try? await transcription.transcribe(url: url)) ?? ""
            note.originalText = text
            note.isTranscribing = false
            if autoCopy && !text.isEmpty {
                UIPasteboard.general.string = text
            }
        }
    }

    private func delete(_ note: Note) {
        if let url = note.audioURL {
            try? FileManager.default.removeItem(at: url)
        }
        modelContext.delete(note)
    }

    /// Notes stuck in `isTranscribing` from a previous run (app killed mid-job)
    /// flip back to the normal empty/retry state.
    private func resetOrphanedTranscriptions() {
        for note in notes where note.isTranscribing {
            note.isTranscribing = false
        }
    }

    private func handleAppReady() {
        guard hasCompletedSetup else { return }
        runStartupWorkIfNeeded()
        presentRecorderForLaunchIfNeeded()
    }

    private func runStartupWorkIfNeeded() {
        guard !didRunStartupWork else { return }
        didRunStartupWork = true
        // Unstructured task: an `async let` here would be cancelled the
        // moment this scope exits, killing the warm-up right after launch.
        Task { await transcription.prepare() }
        resetOrphanedTranscriptions()
    }

    /// "Record on open" no longer takes over the screen — it just expands
    /// the dock into the recording pill over whatever is showing.
    private func presentRecorderForLaunchIfNeeded() {
        guard launchRecordingGate.shouldStartRecording(
            hasCompletedSetup: hasCompletedSetup,
            recordOnLaunch: recordOnLaunch,
            recorderIsPresented: recording.isActive,
            blockingModalIsPresented: showComposer || showSettings
        ) else {
            return
        }

        Task { await recording.begin() }
    }
}

struct NoteCard: View {
    let note: Note

    @Environment(TranscriptionService.self) private var transcription

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(note.createdAt.formatted(date: .numeric, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if note.isTranscribing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(transcription.state.transcribingStatusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(note.originalText.isEmpty ? "No text detected. Tap to retry." : note.originalText)
                    .font(.subheadline)
                    .foregroundStyle(note.originalText.isEmpty ? .secondary : .primary)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
            }

            HStack(spacing: 8) {
                if let styleLabel = note.polishStyleLabel, note.isPolished {
                    Label("Polished · \(styleLabel)", systemImage: "sparkle")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.polishTeal)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.polishTealSoft))
                }
                Spacer()
                if note.source == .voice, let duration = note.durationLabel {
                    Image(systemName: "waveform")
                        .font(.caption2)
                        .foregroundStyle(Color.waveGreen)
                    Text(duration)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                } else if note.source == .text {
                    Text("Aa pasted text")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemGroupedBackground)))
    }
}
