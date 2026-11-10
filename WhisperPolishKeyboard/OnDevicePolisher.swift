import Foundation

/// Polishes text on the phone with the tuned model, inside the keyboard. Loads
/// the model for each polish and frees it after, so the keyboard only carries
/// llama.cpp's buffers while Polish is running.
enum OnDevicePolisher {
    enum Failure: LocalizedError {
        case modelMissing
        case tooLong
        case empty

        var errorDescription: String? {
            switch self {
            case .modelMissing: "Open Whisper Polish and download the Polish model first."
            case .tooLong: "That's too long to polish on the phone. Select a shorter part and try again."
            case .empty: "Polish came back empty. Try again."
            }
        }
    }

    /// Settings measured on an iPhone Air: GPU, 8-bit cache and 256-token batches
    /// polish a typical note in 1.5–4 s. iOS kills the keyboard past 177 MB, so
    /// llama.cpp is told only one position per batch needs scores (see LlamaPolisher).
    private static let contextTokens = 2048

    static func polish(text: String, style: PolishStyle) async throws -> String {
        guard OnDevicePolishModel.isInstalled else { throw Failure.modelMissing }
        return try await Task.detached(priority: .userInitiated) {
            let started = Date()
            PolishLog.write("start chars=\(text.count) style=\(style.id) footprint=\(Int(LabMemory.footprintMB()))MB")
            let peak = LabMemory.PeakWatcher()
            peak.start()
            defer { _ = peak.stop() }
            do {
                let warmSeconds = try warmUp(OnDevicePolishModel.fileURL)
                PolishLog.write(String(format: "file-read %.2fs", warmSeconds))
                let polisher = try LlamaPolisher(
                    modelPath: OnDevicePolishModel.fileURL.path,
                    gpuLayers: 99,
                    contextTokens: contextTokens,
                    threads: 4,
                    cacheBits: 8,
                    extraBuffers: false,
                    microBatch: 256,
                    outputsPerBatch: 1,
                    cpuOnly: false,
                    trace: { PolishLog.write("\($0) footprint=\(Int(LabMemory.footprintMB()))MB") }
                )
                let prompt = try polisher.prompt(system: nil, user: OnDevicePolishModel.userMessage(text: text, style: style))
                let output: LlamaPolisher.Output
                do {
                    output = try polisher.complete(prompt, maxTokens: contextTokens)
                } catch LlamaPolisher.Failure.tooLong {
                    throw Failure.tooLong
                }
                PolishLog.write(String(
                    format: "done in=%d out=%d prefill=%.2fs decode=%.2fs total=%.2fs peak=%.0fMB",
                    output.promptTokens, output.generatedTokens, output.prefillSeconds, output.decodeSeconds,
                    Date().timeIntervalSince(started), peak.stop()))
                guard !output.text.isEmpty else { throw Failure.empty }
                return output.text
            } catch {
                PolishLog.write("failed \(error.localizedDescription)")
                throw error
            }
        }.value
    }

    /// Reads the model straight through so it's in the system's file cache before
    /// llama.cpp maps it. Mapping a file that isn't cached faults it in 16 KB at a
    /// time, which took 12.6 s on the first load after a copy in the lab. One
    /// reused buffer keeps the keyboard's memory flat while 800 MB passes through.
    private static func warmUp(_ url: URL) throws -> Double {
        let started = Date()
        let file = open(url.path, O_RDONLY)
        guard file >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { close(file) }
        let size = 4 * 1_048_576
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16_384)
        defer { buffer.deallocate() }
        while true {
            let count = read(file, buffer, size)
            guard count >= 0 else { throw CocoaError(.fileReadUnknown) }
            if count == 0 { break }
        }
        return Date().timeIntervalSince(started)
    }
}
