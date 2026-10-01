import Foundation
import SwiftData

enum NoteSource: String, Codable {
    case voice
    case text
}

@Model
final class Note {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var sourceRaw: String = NoteSource.voice.rawValue
    var originalText: String = ""
    var audioFileName: String?
    var duration: TimeInterval?
    /// True while a voice note is still being transcribed in the background.
    var isTranscribing: Bool = false

    var polishedText: String?
    var polishStyleRaw: String?
    /// Style name captured at polish time, so the label survives even if a
    /// custom style is later deleted. Nil on notes polished before this field.
    var polishStyleName: String?
    var polishModel: String?
    var polishedAt: Date?

    /// JSON `[FlaggedWord]` for words in `originalText` the recognizer was
    /// unsure about. Stored as data so adding it is a lightweight migration.
    var transcriptFlagsData: Data?

    /// The polish that the latest polish replaced, so it can be undone.
    /// `hasPolishUndo` is separate because the replaced state may be "not
    /// polished yet", where every field is nil.
    var hasPolishUndo: Bool = false
    var previousPolishedText: String?
    var previousPolishStyleRaw: String?
    var previousPolishStyleName: String?
    var previousPolishModel: String?
    var previousPolishedAt: Date?

    init(source: NoteSource, originalText: String, audioFileName: String? = nil, duration: TimeInterval? = nil) {
        self.id = UUID()
        self.createdAt = Date()
        self.sourceRaw = source.rawValue
        self.originalText = originalText
        self.audioFileName = audioFileName
        self.duration = duration
    }

    var source: NoteSource { NoteSource(rawValue: sourceRaw) ?? .voice }
    var isPolished: Bool { polishedText != nil }

    /// Display name of the style this note was polished with.
    var polishStyleLabel: String? {
        polishStyleName ?? polishStyleRaw.flatMap { raw in
            PolishStyle.builtIns.first { $0.id == raw }?.name
        }
    }

    var audioURL: URL? {
        guard let audioFileName else { return nil }
        return URL.documentsDirectory.appending(path: "Audio").appending(path: audioFileName)
    }

    func applyPolish(_ result: PolishResult) {
        hasPolishUndo = true
        previousPolishedText = polishedText
        previousPolishStyleRaw = polishStyleRaw
        previousPolishStyleName = polishStyleName
        previousPolishModel = polishModel
        previousPolishedAt = polishedAt

        polishedText = result.text
        polishStyleRaw = result.style.id
        polishStyleName = result.style.name
        polishModel = result.model
        polishedAt = Date()
    }

    /// Restores the polish from before the latest one. One level only.
    func undoPolish() {
        guard hasPolishUndo else { return }
        polishedText = previousPolishedText
        polishStyleRaw = previousPolishStyleRaw
        polishStyleName = previousPolishStyleName
        polishModel = previousPolishModel
        polishedAt = previousPolishedAt
        clearPolishUndo()
    }

    private func clearPolishUndo() {
        hasPolishUndo = false
        previousPolishedText = nil
        previousPolishStyleRaw = nil
        previousPolishStyleName = nil
        previousPolishModel = nil
        previousPolishedAt = nil
    }

    var transcript: Transcript {
        get {
            let flags = transcriptFlagsData.flatMap { try? JSONDecoder().decode([FlaggedWord].self, from: $0) } ?? []
            return Transcript(text: originalText, flags: flags)
        }
        set {
            originalText = newValue.text
            transcriptFlagsData = newValue.flags.isEmpty ? nil : try? JSONEncoder().encode(newValue.flags)
        }
    }

    var durationLabel: String? {
        guard let duration else { return nil }
        let total = Int(duration.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
