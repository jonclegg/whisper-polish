import Foundation
import FluidAudio
import Observation

@MainActor
@Observable
final class TranscriptionService {
    enum State: Equatable {
        case idle
        case downloading
        case ready
        case failed(String)
    }

    private(set) var state: State = .idle
    private var manager: AsrManager?

    /// Downloads (first run) and loads the Parakeet V3 CoreML models.
    func prepare() async {
        guard state == .idle || state.isFailure else { return }
        state = .downloading
        do {
            let models = try await AsrModels.downloadAndLoad()
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            self.manager = manager
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func transcribe(url: URL) async throws -> String {
        if manager == nil { await prepare() }
        guard let manager else {
            throw TranscriptionError.notReady
        }
        var decoderState = try TdtDecoderState()
        let result = try await manager.transcribe(url, decoderState: &decoderState)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TranscriptionError: LocalizedError {
    case notReady

    var errorDescription: String? {
        "The transcription model isn't ready yet. Check your connection and try again."
    }
}

private extension TranscriptionService.State {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
