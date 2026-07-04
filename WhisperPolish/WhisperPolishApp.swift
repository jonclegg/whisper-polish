import SwiftUI
import SwiftData

@main
struct WhisperPolishApp: App {
    @State private var transcription = TranscriptionService()

    var body: some Scene {
        WindowGroup {
            NotesListView()
                .environment(transcription)
                .tint(.polishTeal)
        }
        .modelContainer(for: Note.self)
    }
}
