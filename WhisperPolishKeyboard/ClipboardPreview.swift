import UIKit

/// What the system keyboard shows above the keys when the pasteboard has new text.
/// Images aren't offered: a keyboard can only insert text into the host.
struct ClipboardPreview {
    var text: String
    var changeCount: Int

    var accessibilityLabel: String { "Paste \(Self.displayText(text))" }

    /// A short single-block preview. The pasted value stays the original string.
    static func displayText(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if flat.count <= 180 { return flat }
        return String(flat.prefix(180))
    }

    static func load(from pasteboard: UIPasteboard = .general) -> ClipboardPreview? {
        guard pasteboard.hasStrings, let text = pasteboard.string else { return nil }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ClipboardPreview(text: text, changeCount: pasteboard.changeCount)
    }
}
