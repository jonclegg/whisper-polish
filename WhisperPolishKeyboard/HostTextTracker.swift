import Foundation

/// The text before the cursor as the keyboard's own edits left it.
///
/// Hosts report text changes back asynchronously, and fast typing outruns
/// them: right after the keyboard's edits the reported context can be several
/// keystrokes behind, and corrections computed from it delete the wrong
/// characters. So the keyboard's own text wins until the host catches up.
///
/// Each read of the host's text is a round trip to the host app, so the host
/// is only asked when the keyboard doesn't already know the answer.
struct HostTextTracker {
    /// Reports this long after the last edit that still disagree mean the
    /// user or the app changed the text.
    static let hostLag: TimeInterval = 1
    static let length = 300

    private(set) var local: String?
    private var document: UUID?
    /// Typing never changes the text after the cursor, so a different report means the cursor moved.
    private var after: String?
    private var lastEdit = Date.distantPast

    func textBefore(reported: @autoclosure () -> String?) -> String {
        local ?? reported() ?? ""
    }

    /// Call before handing the insert to the host.
    mutating func willInsert(
        _ text: String,
        reported: @autoclosure () -> String?,
        after: @autoclosure () -> String?,
        document: @autoclosure () -> UUID?,
        at now: Date = Date()
    ) {
        record(textBefore(reported: reported()) + text, after: after(), document: document(), at: now)
    }

    /// Call before handing the deletes to the host.
    mutating func willDelete(
        _ count: Int,
        reported: @autoclosure () -> String?,
        after: @autoclosure () -> String?,
        document: @autoclosure () -> UUID?,
        at now: Date = Date()
    ) {
        record(String(textBefore(reported: reported()).dropLast(count)), after: after(), document: document(), at: now)
    }

    /// For edits that can't be followed character by character, like cursor moves.
    mutating func forget() {
        local = nil
    }

    /// Goes back to the host's text once it has caught up, or once it's clear
    /// something else changed the text.
    mutating func reconcile(reported: String?, after: String?, document: UUID?, at now: Date = Date()) {
        guard let local else { return }
        let reported = reported ?? ""
        // Hosts only report text back to a sentence or paragraph boundary.
        let caughtUp = reported.isEmpty ? local.isEmpty : local.hasSuffix(reported)
        let moved = (after ?? "") != (self.after ?? "") || document != self.document
        if caughtUp || moved || now.timeIntervalSince(lastEdit) > Self.hostLag {
            self.local = nil
        }
    }

    /// The text after the cursor and the document only need reading when local tracking starts.
    private mutating func record(_ text: String, after: @autoclosure () -> String?, document: @autoclosure () -> UUID?, at now: Date) {
        if local == nil {
            self.after = after()
            self.document = document()
        }
        local = String(text.suffix(Self.length))
        lastEdit = now
    }
}
