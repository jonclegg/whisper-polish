import Foundation

/// A polish style is just a name plus the prompt fragment injected into the
/// system prompt. Built-ins ship with the app; users can add their own,
/// persisted as JSON in UserDefaults (see `SettingsKeys.customStyles`).
struct PolishStyle: Identifiable, Codable, Equatable, Hashable {
    let id: String
    var name: String
    var instruction: String

    var isBuiltIn: Bool { Self.builtIns.contains { $0.id == id } }

    /// Verbatim styles format the transcript without rewriting it, so they
    /// get their own system prompt (the normal one says to cut filler and
    /// rephrase) and stealth mode — which rewrites by design — doesn't apply.
    var isVerbatim: Bool { id == Self.paragraphs.id }
}

extension PolishStyle {
    static let email = PolishStyle(
        id: "email",
        name: "Email",
        instruction: "Shape it into a short email: a natural greeting, the point up front, a clear ask, and a brief sign-off. Businesslike but warm."
    )
    static let reddit = PolishStyle(
        id: "reddit",
        name: "Reddit post",
        instruction: "Shape it into a Reddit post: conversational, opinionated, first person. A little informal punctuation is fine. No corporate tone."
    )
    static let marketing = PolishStyle(
        id: "marketing",
        name: "Marketing",
        instruction: "Shape it into short marketing copy: punchy, concrete benefits, active voice. Confident but not hypey."
    )
    static let message = PolishStyle(
        id: "message",
        name: "Text message",
        instruction: "Shape it into a text message: casual, brief, contractions everywhere. One or two short paragraphs at most."
    )
    static let cleanup = PolishStyle(
        id: "cleanup",
        name: "Just clean it up",
        instruction: "Keep the same form and tone. Just remove filler, false starts, and repetition, and fix the grammar. Change as little as possible."
    )

    static let paragraphs = PolishStyle(
        id: "paragraphs",
        name: "Just paragraphs",
        instruction: "Break it into paragraphs and fix only obvious grammar mistakes. Keep every word as spoken."
    )

    static let builtIns: [PolishStyle] = [.email, .reddit, .marketing, .message, .cleanup, .paragraphs]

    // MARK: - Custom style persistence

    static func decodeCustom(_ json: String) -> [PolishStyle] {
        guard let data = json.data(using: .utf8),
              let styles = try? JSONDecoder().decode([PolishStyle].self, from: data)
        else { return [] }
        return styles
    }

    static func encodeCustom(_ styles: [PolishStyle]) -> String {
        guard let data = try? JSONEncoder().encode(styles) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func all(customJSON: String) -> [PolishStyle] {
        builtIns + decodeCustom(customJSON)
    }

    static func find(id: String, customJSON: String) -> PolishStyle? {
        all(customJSON: customJSON).first { $0.id == id }
    }
}
