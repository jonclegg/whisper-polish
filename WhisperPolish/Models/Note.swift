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
    var polishStealth: Bool = false
    var polishModel: String?
    var polishedAt: Date?

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
        polishedText = result.text
        polishStyleRaw = result.style.id
        polishStyleName = result.style.name
        polishStealth = result.stealth
        polishModel = result.model
        polishedAt = Date()
    }

    var durationLabel: String? {
        guard let duration else { return nil }
        let total = Int(duration.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
