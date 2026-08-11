import SwiftUI
import SwiftData

@main
struct WhisperPolishApp: App {
    @State private var transcription = TranscriptionService()
    @State private var openRouterKey = OpenRouterKeyStore()
    @State private var subscription = SubscriptionStore()

    var body: some Scene {
        WindowGroup {
            NotesListView()
                .environment(transcription)
                .environment(openRouterKey)
                .environment(subscription)
                .tint(.polishTeal)
        }
        .modelContainer(for: Note.self)
    }
}
