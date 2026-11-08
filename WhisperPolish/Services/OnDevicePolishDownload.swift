import Foundation
import Observation

/// Downloads the keyboard's on-device polish model into the App Group, once,
/// when the person taps Download.
@MainActor
@Observable
final class OnDevicePolishDownload: NSObject {
    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case installed
        case failed(String)
    }

    private(set) var state: State = OnDevicePolishModel.isInstalled ? .installed : .notDownloaded
    @ObservationIgnored private var task: URLSessionDownloadTask?

    static let sizeText = ByteCountFormatter.string(fromByteCount: Int64(OnDevicePolishModel.byteCount), countStyle: .file)

    func start() {
        switch state {
        case .downloading, .installed: return
        case .notDownloaded, .failed: break
        }
        state = .downloading(0)
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        task = session.downloadTask(with: OnDevicePolishModel.remoteURL)
        task?.resume()
    }

    /// Stops the download and keeps nothing partial.
    func cancel() {
        task?.cancel()
        task = nil
        state = .notDownloaded
    }

    private func install(_ location: URL) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: location.path)[.size]) as? Int
        guard size == OnDevicePolishModel.byteCount else {
            throw ModelMirror.MirrorError.sizeMismatch(
                path: OnDevicePolishModel.fileName, expected: OnDevicePolishModel.byteCount, got: size ?? 0)
        }
        let destination = OnDevicePolishModel.fileURL
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: location, to: destination)
    }
}

extension OnDevicePolishDownload: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let fraction = Double(totalBytesWritten) / Double(OnDevicePolishModel.byteCount)
        MainActor.assumeIsolated {
            guard task === downloadTask else { return }
            state = .downloading(min(fraction, 1))
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this returns, so it moves now.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        MainActor.assumeIsolated {
            guard task === downloadTask else { return }
            do {
                guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
                try install(location)
                state = .installed
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task finished: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        MainActor.assumeIsolated {
            guard task === finished else { return }
            task = nil
            if let error { state = .failed(error.localizedDescription) }
        }
    }
}
