import SwiftUI
import SwiftData

struct NotesListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(TranscriptionService.self) private var transcription
    @Query(sort: \Note.createdAt, order: .reverse) private var notes: [Note]

    @AppStorage(SettingsKeys.recordOnLaunch) private var recordOnLaunch = false
    @AppStorage(SettingsKeys.hasCompletedSetup) private var hasCompletedSetup = false
    @State private var path: [Note] = []
    @State private var searchText = ""
    @State private var showRecorder = false
    @State private var showComposer = false
    @State private var showSettings = false
    @State private var didAutoRecord = false

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
                .padding(.bottom, 110)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Whisper Polish")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Note.self) { note in
                NoteDetailView(note: note)
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .overlay(alignment: .bottom) { dock }
        }
        .fullScreenCover(isPresented: $showRecorder) {
            RecordingView { note in
                path.append(note)
            }
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
        )) {
            OnboardingView()
        }
        .task {
            guard hasCompletedSetup else { return }
            async let _ = transcription.prepare()
            if recordOnLaunch && !didAutoRecord {
                didAutoRecord = true
                showRecorder = true
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Tap the record button to capture a voice note,\nor Aa to paste text.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 120)
    }

    private var dock: some View {
        HStack(spacing: 22) {
            Button { showComposer = true } label: {
                Text("Aa")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color(.secondarySystemGroupedBackground)))
                    .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
            }
            Button { showRecorder = true } label: {
                Circle()
                    .fill(Color(.label))
                    .frame(width: 66, height: 66)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 4))
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
            }
            // Placeholder to keep the record button centered.
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.bottom, 12)
    }

    private func delete(_ note: Note) {
        if let url = note.audioURL {
            try? FileManager.default.removeItem(at: url)
        }
        modelContext.delete(note)
    }
}

struct NoteCard: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(note.createdAt.formatted(date: .numeric, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Text(note.originalText.isEmpty ? "No text detected. Tap to retry." : note.originalText)
                .font(.subheadline)
                .foregroundStyle(note.originalText.isEmpty ? .secondary : .primary)
                .lineLimit(4)
                .multilineTextAlignment(.leading)

            HStack(spacing: 8) {
                if let style = note.polishStyle, note.isPolished {
                    Label("Polished · \(style.displayName)", systemImage: "sparkle")
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
