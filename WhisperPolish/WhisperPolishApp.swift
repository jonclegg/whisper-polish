import SwiftUI
import SwiftData

@main
struct WhisperPolishApp: App {
    @State private var transcription = TranscriptionService()

    init() {
        perfLog("app launched")
    }

    var body: some Scene {
        WindowGroup {
            NotesListView()
                .environment(transcription)
                .tint(.polishTeal)
        }
        .modelContainer(for: Note.self)
    }
}
