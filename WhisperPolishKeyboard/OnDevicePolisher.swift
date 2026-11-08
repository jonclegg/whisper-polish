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
    /// polish a typical note in 1.5–4 s at about 120 MB.
    private static let contextTokens = 2048

    static func polish(text: String, style: PolishStyle) async throws -> String {
        guard OnDevicePolishModel.isInstalled else { throw Failure.modelMissing }
        return try await Task.detached(priority: .userInitiated) {
            let polisher = try LlamaPolisher(
                modelPath: OnDevicePolishModel.fileURL.path,
                gpuLayers: 99,
                contextTokens: contextTokens,
                threads: 4,
                cacheBits: 8,
                extraBuffers: false,
                microBatch: 256,
                cpuOnly: false
            )
            let prompt = try polisher.prompt(system: nil, user: OnDevicePolishModel.userMessage(text: text, style: style))
            let output: LlamaPolisher.Output
            do {
                output = try polisher.complete(prompt, maxTokens: contextTokens)
            } catch LlamaPolisher.Failure.tooLong {
                throw Failure.tooLong
            }
            guard !output.text.isEmpty else { throw Failure.empty }
            return output.text
        }.value
    }
}
