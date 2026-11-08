import SwiftUI
import SwiftData

@main
struct WhisperPolishApp: App {
    @State private var transcription = TranscriptionService()
    @State private var subscription = SubscriptionStore()
    @State private var polishModel = OnDevicePolishDownload()

    init() {
        AppGroup.migrateStandardDefaults()
    }

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("-lab") {
                LabView()
            } else {
                NotesListView()
                    .environment(transcription)
                    .environment(subscription)
                    .environment(polishModel)
                    .tint(.polishTeal)
            }
        }
        .modelContainer(for: Note.self)
    }
}
