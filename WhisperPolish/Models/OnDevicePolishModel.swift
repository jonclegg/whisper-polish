import Foundation

/// The small polish model the keyboard runs on the phone: Qwen3.5-0.8B tuned (round three, on fact-checked examples, then preference-trained away from its own invented details) on
/// dictated and phone-typed notes. The app downloads it into the App Group once,
/// and the keyboard memory-maps it from there. Its tokenizer keeps only Latin-script
/// tokens (scripts/on-device-polish/prune_vocab.py), which cuts about 37 MB from
/// the keyboard while polishing and gives the same polishes.
enum OnDevicePolishModel {
    static let fileName = "qwen3.5-0.8b-r3dpo-latin-Q8_0.gguf"
    static let byteCount = 688_852_288
    static let remoteURL = ModelHost.baseURL.appendingPathComponent("polish/\(fileName)")

    static var fileURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)!
            .appendingPathComponent("polish-model", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    static var isInstalled: Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? Int
        return size == byteCount
    }

    /// The prompt the model was tuned on: no system prompt, the style then the text.
    static func userMessage(text: String, style: PolishStyle) -> String {
        "Style: \(style.instruction)\n\nText:\n\(text)"
    }
}

/// CloudFront distribution in front of the S3 bucket that serves model files.
enum ModelHost {
    static let baseURL = URL(string: "https://d36t08oi3ecji2.cloudfront.net")!
}
