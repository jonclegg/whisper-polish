import Foundation
import SwiftData

enum NoteSource: String, Codable {
    case voice
    case text
}

enum PolishStyle: String, CaseIterable, Codable, Identifiable {
    case email
    case reddit
    case marketing
    case message
    case cleanup

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .email: return "Email"
        case .reddit: return "Reddit post"
        case .marketing: return "Marketing"
        case .message: return "Text message"
        case .cleanup: return "Just clean it up"
        }
    }

    var instruction: String {
        switch self {
        case .email:
            return "Shape it into a short email: a natural greeting, the point up front, a clear ask, and a brief sign-off. Businesslike but warm."
        case .reddit:
            return "Shape it into a Reddit post: conversational, opinionated, first person. A little informal punctuation is fine. No corporate tone."
        case .marketing:
            return "Shape it into short marketing copy: punchy, concrete benefits, active voice. Confident but not hypey."
        case .message:
            return "Shape it into a text message: casual, brief, contractions everywhere. One or two short paragraphs at most."
        case .cleanup:
            return "Keep the same form and tone. Just remove filler, false starts, and repetition, and fix the grammar. Change as little as possible."
        }
    }
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
    var polishStyle: PolishStyle? { polishStyleRaw.flatMap(PolishStyle.init(rawValue:)) }
    var isPolished: Bool { polishedText != nil }

    var audioURL: URL? {
        guard let audioFileName else { return nil }
        return URL.documentsDirectory.appending(path: "Audio").appending(path: audioFileName)
    }

    func applyPolish(_ result: PolishResult) {
        polishedText = result.text
        polishStyleRaw = result.style.rawValue
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
