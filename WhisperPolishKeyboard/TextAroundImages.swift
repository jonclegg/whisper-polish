import Foundation

/// A field's text split around its images. Keyboards see an image as an
/// object replacement character and can't type one back, so polishing works
/// on the text between images and steps the cursor over the images instead
/// of deleting them.
struct TextAroundImages {
    static let image: Character = "\u{FFFC}"

    enum Edit: Equatable {
        case delete(Int)
        case insert(String)
        /// Cursor moves count UTF-16 units, like the host's text ranges.
        case move(Int)
    }

    /// The text before the first image, between images, and after the last one.
    let runs: [String]

    init(_ text: String) {
        runs = text.split(separator: Self.image, omittingEmptySubsequences: false).map(String.init)
    }

    var hasText: Bool {
        runs.contains { !Self.isBlank($0) }
    }

    static func isBlank(_ run: String) -> Bool {
        run.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `polished` in place of `run`, keeping the spaces and line breaks that sat against the images.
    static func fitting(_ polished: String, into run: String) -> String {
        let leading = run.prefix { $0.isWhitespace }
        let trailing = run.dropFirst(leading.count).reversed().prefix { $0.isWhitespace }
        return String(leading) + polished.trimmingCharacters(in: .whitespacesAndNewlines) + String(trailing.reversed())
    }

    /// Edits that turn the runs `old` into `new`, starting and ending with the
    /// cursor at the end of the last run: each run is replaced from the last
    /// to the first, and the cursor hops over the image before it.
    static func edits(from old: [String], to new: [String]) -> [Edit] {
        precondition(old.count == new.count)
        var edits: [Edit] = []
        for index in old.indices.reversed() {
            if old[index] != new[index] {
                if !old[index].isEmpty { edits.append(.delete(old[index].count)) }
                if !new[index].isEmpty { edits.append(.insert(new[index])) }
            }
            if index > 0 { edits.append(.move(-(new[index].utf16.count + 1))) }
        }
        let back = new.dropFirst().reduce(0) { $0 + $1.utf16.count + 1 }
        if back > 0 { edits.append(.move(back)) }
        return edits
    }
}
