import UIKit

/// Keyboards only see the text around the cursor, cut off at sentence and
/// paragraph boundaries. Reading the whole field means walking the cursor
/// to the start, then to the end, collecting text along the way.
@MainActor
struct DocumentReader {
    let proxy: UITextDocumentProxy

    /// Returns the field's full text and leaves the cursor at its end.
    func readWholeDocument() async -> String {
        await moveToStart()
        return await readToEnd()
    }

    private func moveToStart() async {
        while true {
            let before = proxy.documentContextBeforeInput ?? ""
            let moved = await move(by: before.isEmpty ? -1 : -before.count)
            if !moved { return }
        }
    }

    private func readToEnd() async -> String {
        var text = ""
        while true {
            let after = proxy.documentContextAfterInput ?? ""
            guard await move(by: after.isEmpty ? 1 : after.count) else { return text }
            guard after.isEmpty else {
                text += after
                continue
            }
            // Stepped one character over a boundary. It's the last character
            // before the cursor, unless the context restarted at a new
            // paragraph, in which case it was a line break.
            text += (proxy.documentContextBeforeInput ?? "").last.map(String.init) ?? "\n"
        }
    }

    /// Moves the cursor and reports whether it actually moved, judged by
    /// whether the context around it changed.
    private func move(by offset: Int) async -> Bool {
        guard !Task.isCancelled else { return false }
        let before = proxy.documentContextBeforeInput
        let after = proxy.documentContextAfterInput
        proxy.adjustTextPosition(byCharacterOffset: offset)
        // The host applies cursor moves asynchronously.
        try? await Task.sleep(for: .milliseconds(50))
        return proxy.documentContextBeforeInput != before || proxy.documentContextAfterInput != after
    }
}
