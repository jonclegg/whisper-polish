import Foundation

/// A polish style is just a name plus the prompt fragment injected into the
/// system prompt. Built-ins ship with the app; users can add their own,
/// persisted as JSON in UserDefaults (see `SettingsKeys.customStyles`).
struct PolishStyle: Identifiable, Codable, Equatable, Hashable {
    let id: String
    var name: String
    var instruction: String

    var isBuiltIn: Bool { Self.builtIns.contains { $0.id == id } }
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
    static let slack = PolishStyle(
        id: "slack",
        name: "Slack update",
        instruction: "Shape it into a Slack message to coworkers: friendly and direct, short lines, no greeting or sign-off. Get to the point in the first line."
    )
    static let bullets = PolishStyle(
        id: "bullets",
        name: "Bullet summary",
        instruction: "Shape it into a tight bullet summary: one short line per point, most important first. A one-line lead-in is fine. Drop anything that isn't a point."
    )
    static let blog = PolishStyle(
        id: "blog",
        name: "Blog post",
        instruction: "Shape it into a short blog post: a hook up front, one clear thread through the middle, an ending that lands. First person, conversational but composed."
    )
    static let social = PolishStyle(
        id: "social",
        name: "Social post",
        instruction: "Shape it into a social media post: one or two punchy sentences that make the point fast. No hashtags or emoji unless they were spoken."
    )
    static let formal = PolishStyle(
        id: "formal",
        name: "Formal",
        instruction: "Shape it into formal, professional writing: measured tone, precise wording, complete sentences, no slang. Polished but still human."
    )

    static let builtIns: [PolishStyle] = [
        .email, .message, .slack, .reddit, .social, .blog, .marketing, .bullets, .formal, .cleanup,
    ]

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
