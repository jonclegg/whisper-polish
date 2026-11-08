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

    /// Called by the app each time it comes to the front.
    static func mirrorToDocuments() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("polish-log.txt")
        try? FileManager.default.removeItem(at: documents)
        try? FileManager.default.copyItem(at: groupURL, to: documents)
    }
}
