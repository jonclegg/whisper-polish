import Foundation
import FluidAudio
import Observation
import WhisperKit

enum TranscriptionEngine: String, CaseIterable, Identifiable {
    case parakeet
    case whisper

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .parakeet: return "Parakeet V3"
        case .whisper: return "Whisper"
        }
    }

    var subtitle: String {
        switch self {
        case .parakeet: return "25 European languages · fastest"
        case .whisper: return "99 languages · good accuracy"
        }
    }

    var sizeLabel: String {
        switch self {
        case .parakeet: return "~500 MB"
        case .whisper: return "~550 MB"
        }
    }

    /// WhisperKit model variant (Whisper only).
    var whisperVariant: String { "small.en" }
}

@MainActor
@Observable
final class TranscriptionService {
    enum State: Equatable {
        case idle
        /// Downloading model files from the mirror; fraction is 0...1 when known.
        case downloading(Double?)
        /// Files are local; loading model assets into memory.
        case loading
        case ready
        case failed(String)

        var isDownloading: Bool {
            if case .downloading = self { return true }
            return false
        }

        var transcribingStatusMessage: String {
            switch self {
            case .downloading(let fraction):
                if let fraction {
                    return "Downloading transcription model... \(Int(fraction * 100))%"
                }
                return "Preparing transcription model..."
            case .loading:
                return "Loading transcription model..."
            default:
                return "Transcribing..."
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var loadedEngine: TranscriptionEngine?
    private var parakeet: AsrManager?
    private var whisper: WhisperKit?
    private var prepareTask: Task<Void, Never>?

    var selectedEngine: TranscriptionEngine {
        TranscriptionEngine(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.engine) ?? "") ?? .parakeet
    }

    /// True when the currently selected engine is loaded and ready.
    var isReady: Bool { state == .ready && loadedEngine == selectedEngine }

    /// Downloads (first run) and loads the selected engine's models.
    /// Safe to call repeatedly; concurrent calls share one load.
    func prepare() async {
        if isReady { return }
        if let prepareTask {
            await prepareTask.value
            if isReady { return }
        }
        let engine = selectedEngine
        let task = Task { await load(engine: engine) }
        prepareTask = task
        await task.value
        prepareTask = nil
    }

    private func load(engine: TranscriptionEngine) async {
        do {
            switch engine {
            case .parakeet:
                // Pull from our CloudFront mirror into FluidAudio's cache dir.
                // Byte-accurate progress; FluidAudio then loads from cache offline.
                if !ModelMirror.isComplete() {
                    state = .downloading(nil)
                    try await ModelMirror.download { [weak self] fraction in
                        Task { @MainActor in self?.noteDownload(fraction) }
                    }
                }
                state = .loading
                let models = try await AsrModels.downloadAndLoad()
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                parakeet = manager
                whisper = nil
            case .whisper:
                state = .downloading(nil)
                let folder = try await WhisperKit.download(variant: engine.whisperVariant, progressCallback: { [weak self] progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in self?.noteDownload(fraction) }
                })
                state = .loading
                let config = WhisperKitConfig(
                    model: engine.whisperVariant,
                    modelFolder: folder.path,
                    load: true,
                    download: false
                )
                whisper = try await WhisperKit(config)
                parakeet = nil
            }
            loadedEngine = engine
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func noteDownload(_ fraction: Double) {
        if state.isDownloading {
            state = .downloading(fraction)
        }
    }

    func transcribe(url: URL) async throws -> String {
        if !isReady { await prepare() }
        switch (loadedEngine, parakeet, whisper) {
        case (.parakeet, let manager?, _):
            var decoderState = try TdtDecoderState()
            let result = try await manager.transcribe(url, decoderState: &decoderState)
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        case (.whisper, _, let pipe?):
            let results = try await pipe.transcribe(audioPath: url.path)
            return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            throw TranscriptionError.notReady
        }
    }
}

enum TranscriptionError: LocalizedError {
    case notReady

    var errorDescription: String? {
        "The transcription model isn't ready yet. Check your connection and try again."
    }
}
