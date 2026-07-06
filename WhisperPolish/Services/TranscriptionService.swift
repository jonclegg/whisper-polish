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

    /// Cancels an in-flight model download. If another engine was already
    /// loaded, the selection reverts to it so transcription keeps working.
    func cancelPreparation() {
        prepareTask?.cancel()
    }

    /// Downloads (first run) and loads the selected engine's models.
    /// Safe to call repeatedly; concurrent calls share one load.
    func prepare() async {
        perfLog("prepare() called, state=\(state)")
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
                let mirrorCheckStart = Date()
                let mirrorComplete = ModelMirror.isComplete()
                perfLog("ModelMirror.isComplete=\(mirrorComplete): \(Date().timeIntervalSince(mirrorCheckStart))s")
                if !mirrorComplete {
                    state = .downloading(nil)
                    let mirrorStart = Date()
                    try await ModelMirror.download { [weak self] fraction in
                        Task { @MainActor in self?.noteDownload(fraction) }
                    }
                    perfLog("ModelMirror.download: \(Date().timeIntervalSince(mirrorStart))s")
                }
                state = .loading
                let loadStart = Date()
                let models = try await AsrModels.downloadAndLoad()
                perfLog("AsrModels.downloadAndLoad: \(Date().timeIntervalSince(loadStart))s")
                let managerStart = Date()
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                perfLog("AsrManager.loadModels: \(Date().timeIntervalSince(managerStart))s")
                parakeet = manager
                whisper = nil
            case .whisper:
                // Never touch the network (or the model files) when the model is
                // already on disk: WhisperKit.download re-syncs against HuggingFace
                // and rewrites files, which invalidates iOS's compiled-model cache
                // and forces a minutes-long re-optimization on the next load.
                var folder = Self.whisperModelFolder(variant: engine.whisperVariant)
                let cached = Self.whisperModelIsCached(at: folder)
                perfLog("whisper model cached=\(cached) at \(folder.path)")
                if !cached {
                    state = .downloading(nil)
                    let downloadStart = Date()
                    folder = try await WhisperKit.download(variant: engine.whisperVariant, progressCallback: { [weak self] progress in
                        let fraction = progress.fractionCompleted
                        Task { @MainActor in self?.noteDownload(fraction) }
                    })
                    perfLog("WhisperKit.download: \(Date().timeIntervalSince(downloadStart))s")
                }
                state = .loading
                let config = WhisperKitConfig(
                    model: engine.whisperVariant,
                    modelFolder: folder.path,
                    load: true,
                    download: false
                )
                let whisperStart = Date()
                whisper = try await WhisperKit(config)
                perfLog("WhisperKit load: \(Date().timeIntervalSince(whisperStart))s")
                parakeet = nil
            }
            loadedEngine = engine
            state = .ready
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                if let loadedEngine {
                    UserDefaults.standard.set(loadedEngine.rawValue, forKey: SettingsKeys.engine)
                    state = .ready
                } else {
                    state = .idle
                }
            } else {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Where WhisperKit.download stores the model (HubApi's default layout
    /// under Documents). Must stay in sync with the `download` call above.
    private static func whisperModelFolder(variant: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/\(variant)")
    }

    private static func whisperModelIsCached(at folder: URL) -> Bool {
        let required = [
            "config.json",
            "AudioEncoder.mlmodelc/weights/weight.bin",
            "TextDecoder.mlmodelc/weights/weight.bin",
            "MelSpectrogram.mlmodelc/weights/weight.bin",
        ]
        return required.allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
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

/// Timing diagnostics: stderr for attached consoles, plus an append-only file
/// in Application Support so timings survive with no console attached.
func perfLog(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "[perf] \(stamp) \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first!.appendingPathComponent("perf.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    } else {
        try? Data(line.utf8).write(to: url)
    }
}

enum TranscriptionError: LocalizedError {
    case notReady

    var errorDescription: String? {
        "The transcription model isn't ready yet. Check your connection and try again."
    }
}
