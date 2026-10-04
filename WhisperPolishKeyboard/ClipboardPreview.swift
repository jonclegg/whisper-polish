import UIKit

/// What the system keyboard shows above the keys when the pasteboard has something new.
struct ClipboardPreview {
    enum Kind {
        case text(String)
        case image(UIImage)
    }

    var kind: Kind
    var changeCount: Int

    var accessibilityLabel: String {
        switch kind {
        case .text(let text): "Paste \(Self.displayText(text))"
        case .image: "Paste photo"
        }
    }

    /// A short single-block preview. The pasted value stays the original string.
    static func displayText(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if flat.count <= 180 { return flat }
        return String(flat.prefix(180))
    }

    static func load(from pasteboard: UIPasteboard = .general) -> ClipboardPreview? {
        if pasteboard.hasImages, let thumbnail = thumbnail(from: pasteboard) {
            return ClipboardPreview(kind: .image(thumbnail), changeCount: pasteboard.changeCount)
        }
        guard pasteboard.hasStrings, let text = pasteboard.string else { return nil }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ClipboardPreview(kind: .text(text), changeCount: pasteboard.changeCount)
    }

    private static func thumbnail(from pasteboard: UIPasteboard) -> UIImage? {
        autoreleasepool {
            guard let image = pasteboard.image else { return nil }
            return image.preparingThumbnail(of: CGSize(width: 96, height: 96)) ?? image
        }
    }
}
