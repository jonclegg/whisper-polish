import Foundation
import Observation

/// App-wide recording state behind the persistent dock. Recording is no
/// longer a modal screen — the dock expands into a pill wherever you are,
/// so this controller outlives any single view.
@MainActor
@Observable
final class RecordingController {
    enum Phase: Equatable {
        case idle
        case starting
        case recording
    }

    private(set) var phase: Phase = .idle
    var errorMessage: String?

    let recorder = AudioRecorder()

    var isActive: Bool { phase != .idle }

    func begin() async {
        guard phase == .idle else { return }
        phase = .starting
        guard await AudioRecorder.requestPermission() else {
            phase = .idle
            errorMessage = "Microphone access is off. Enable it in Settings → Privacy → Microphone."
            return
        }
        do {
            try await recorder.start()
            phase = .recording
        } catch {
            phase = .idle
            errorMessage = error.localizedDescription
        }
    }

    func stop() -> (url: URL, duration: TimeInterval)? {
        guard isActive else { return nil }
        phase = .idle
        return recorder.stop()
    }

    func cancel() {
        guard isActive else { return }
        phase = .idle
        recorder.cancel()
    }
}
