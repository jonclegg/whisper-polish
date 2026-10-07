import CryptoKit
import Foundation
import Observation
import os

/// S1-mini by Superwhisper: a 0.6B model fine-tuned for one job, turning a raw
/// speech transcript into clean written text. It runs on this Mac through
/// llama.cpp, so choosing it means no dictated text leaves the machine.
///
/// Measured against Groq's gpt-oss-120b on the same 44 synthetic dictations it
/// scored 94.6 to Groq's 95.4, at a 185ms median instead of 958ms.
enum S1Mini {
    /// Its license requires this exact name, capitalization included, wherever
    /// the model is identified.
    static let displayName = "S1-mini by Superwhisper"

    /// Pinned to one commit so the file can never change under the checksum.
    static let file = ModelMirror.Manifest.File(path: "s1-mini-q4_k_m.gguf", size: 484_219_808)
    static let sha256 = "3b41ebe2502cbd03e811d5d16b022f5ab551eda58d62597d152f89535003c634"
    static let remoteURL = URL(string:
        "https://huggingface.co/superwhisper/s1-mini-GGUF/resolve/34add00a48a2e5d24e5a4ee5405a99620a3a240c/s1-mini-q4_k_m.gguf")!

    static var localURL: URL {
        ModelCatalog.whisperDownloadBase
            .appendingPathComponent("cleanup", isDirectory: true)
            .appendingPathComponent(file.path)
    }

    static var isInstalled: Bool {
        (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int) == file.size
    }

    /// The model card is explicit that this exact system prompt and a control
    /// line are part of the input format it was trained on; any other wording
    /// can make it hallucinate. Semi-formal is its recommended default:
    /// standard capitalization and punctuation, contractions kept.
    static let systemPrompt = """
        You are a text normalizer for speech-to-text transcripts. The input begins \
        with a control line specifying the styling, structure, and context settings; \
        clean the transcript to match those settings and output only the cleaned text.
        """
    static let controlLine = "[Styling: semi-formal] [Structure: prose] [Context: general]"

    /// Qwen3's chat format with thinking switched off (the empty think block),
    /// which the model requires: with thinking on it returns nothing at all.
    static func prompt(for transcript: String) -> [LlamaRunner.Segment] {
        [
            .init(text: "<|im_start|>system\n\(systemPrompt)<|im_end|>\n<|im_start|>user\n\(controlLine)\n",
                  special: true),
            .init(text: transcript, special: false),
            .init(text: "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n", special: true),
        ]
    }

    static func fileSHA256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum S1MiniError: LocalizedError, Equatable {
    case notInstalled
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Download \(S1Mini.displayName) in Settings > Cleanup."
        case .checksumMismatch:
            return "The downloaded model did not match its checksum and was deleted. Try again."
        }
    }
}

/// The on-device cleaner, for dictation and for ⌘⇧1. `prompt` and `model`
/// are ignored: S1-mini has one fixed prompt and is the model.
final class S1MiniCleaner: TextCleaning, TextFixing {
    private let loader = Loader()

    func clean(_ text: String, prompt: String, model: String) async throws -> String {
        let runner = try await loader.runner()
        let cleaned = try await runner.complete(S1Mini.prompt(for: text))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // S1-mini answers nothing when the input was only filler. The
        // coordinator's contract is the same as for Groq: no text means fall
        // back to the raw transcript rather than paste nothing.
        guard !cleaned.isEmpty else { throw PolishError.emptyResponse }
        return cleaned
    }

    /// The same cleanup, run over text selected for ⌘⇧1, reporting the
    /// answer so far as it is written so the fix dialog can show it.
    func fix(_ text: String, onText: @escaping @Sendable (String) -> Void) async throws -> String {
        let runner = try await loader.runner()
        let fixed = try await runner.complete(S1Mini.prompt(for: text), onText: onText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fixed.isEmpty else { throw FixError.emptyResponse }
        return fixed
    }

    /// Loads and warms the model ahead of the first dictation or fix, so the
    /// first one is as fast as the rest.
    func prewarm() async {
        do {
            _ = try await loader.runner()
        } catch {
            Diagnostics.log("s1-mini: prewarm failed: \(Diagnostics.describe(error))")
        }
    }

    func unload() async { await loader.unload() }

    /// Loads the model at most once, shared by every caller that asks while
    /// it is loading. The load itself runs detached, so a dictation that gives
    /// up waiting (its cleanup timed out) does not abandon a load the next
    /// dictation will want.
    private actor Loader {
        private var loaded: LlamaRunner?
        private var loading: Task<LlamaRunner, Error>?

        func runner() async throws -> LlamaRunner {
            if let loaded { return loaded }
            if let loading { return try await loading.value }
            guard S1Mini.isInstalled else { throw S1MiniError.notInstalled }
            let path = S1Mini.localURL.path
            let task = Task.detached(priority: .userInitiated) {
                let runner = try LlamaRunner(modelPath: path)
                // The first generation also compiles llama.cpp's Metal
                // kernels, about a second on its own. Paying that here keeps
                // it out of the first real dictation.
                _ = try await runner.complete(S1Mini.prompt(for: "um hello"))
                return runner
            }
            loading = task
            defer { loading = nil }
            let runner = try await task.value
            loaded = runner
            return runner
        }

        func unload() { loaded = nil }
    }
}

/// Install state of the S1-mini file, for Settings, plus the cleaner that
/// uses it.
@MainActor
@Observable
final class S1MiniModel {
    enum State: Equatable {
        case notInstalled
        case downloading(Double)
        case installed
    }

    private(set) var state: State = S1Mini.isInstalled ? .installed : .notInstalled
    private(set) var lastError: String?
    let cleaner = S1MiniCleaner()

    func install() async {
        guard state == .notInstalled else { return }
        state = .downloading(0)
        lastError = nil
        // The downloader reports every chunk; the UI only needs a step per
        // half percent.
        let lastStep = OSAllocatedUnfairLock(initialState: -1)
        do {
            try await ModelMirror.downloadFile(
                S1Mini.file, from: S1Mini.remoteURL, to: S1Mini.localURL,
                onBytes: { bytes in
                    let step = bytes * 200 / S1Mini.file.size
                    guard lastStep.withLock({ last in
                        defer { last = step }
                        return step != last
                    }) else { return }
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.state else { return }
                        self.state = .downloading(Double(step) / 200)
                    }
                })
            let digest = try await Task.detached { try S1Mini.fileSHA256(at: S1Mini.localURL) }.value
            guard digest == S1Mini.sha256 else {
                try? FileManager.default.removeItem(at: S1Mini.localURL)
                throw S1MiniError.checksumMismatch
            }
            state = .installed
            await cleaner.prewarm()
        } catch {
            state = .notInstalled
            lastError = error.localizedDescription
            Diagnostics.log("s1-mini: install failed: \(Diagnostics.describe(error))")
        }
    }

    func delete() async {
        await cleaner.unload()
        try? FileManager.default.removeItem(at: S1Mini.localURL)
        state = .notInstalled
    }
}
