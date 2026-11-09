import Foundation

/// A short record of on-device polishes (stages, timings, memory), written by
/// the keyboard as each polish runs so a polish the system kills still leaves
/// its last stage behind. The app copies it into Documents, where a Mac can
/// pull it with devicectl.
enum PolishLog {
    private static let maximumBytes = 64 * 1024

    private static var groupURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)!
            .appendingPathComponent("polish-log.txt")
    }

    static func write(_ event: String) {
        let stamp = Date().formatted(.iso8601.time(includingFractionalSeconds: true))
        let line = Data("\(stamp) \(event)\n".utf8)
        let url = groupURL
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int, size > maximumBytes,
           let old = try? Data(contentsOf: url) {
            try? old.suffix(maximumBytes / 2).write(to: url)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? line.write(to: url)
            return
        }
        handle.seekToEndOfFile()
        handle.write(line)
        try? handle.synchronize()
        try? handle.close()
    }

    /// Called by the app each time it comes to the front; also copies the history.
    static func mirrorToDocuments() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for (source, name) in [(groupURL, "polish-log.txt"), (PolishHistory.groupURL, "polish-history.jsonl")] {
            let copy = documents.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.copyItem(at: source, to: copy)
        }
    }
}

/// Every on-device polish the keyboard makes: the text it was given, the style,
/// and what came back, plus a line when the person taps Undo on it. Kept on the
/// phone, one JSON object per line, so bad polishes can be studied later. The
/// app copies it into Documents with the log.
enum PolishHistory {
    private static let maximumBytes = 20 * 1_048_576

    static var groupURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)!
            .appendingPathComponent("polish-history.jsonl")
    }

    static func recordPolish(id: UUID, input: String, style: PolishStyle, output: String, seconds: Double) {
        append([
            "time": Date().formatted(.iso8601), "id": id.uuidString, "event": "polish",
            "model": OnDevicePolishModel.fileName, "style": style.id, "instruction": style.instruction,
            "input": input, "output": output, "seconds": (seconds * 100).rounded() / 100,
        ])
    }

    static func recordUndo(id: UUID) {
        append(["time": Date().formatted(.iso8601), "id": id.uuidString, "event": "undo"])
    }

    private static func append(_ entry: [String: Any]) {
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        let url = groupURL
        // Past the cap, the oldest half goes, cut at a line break.
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int, size > maximumBytes,
           let old = try? Data(contentsOf: url) {
            let tail = old.suffix(maximumBytes / 2)
            let start = tail.firstIndex(of: 0x0A).map { tail.index(after: $0) } ?? tail.startIndex
            try? tail[start...].write(to: url)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? line.write(to: url)
            return
        }
        handle.seekToEndOfFile()
        handle.write(line)
        try? handle.close()
    }
}
