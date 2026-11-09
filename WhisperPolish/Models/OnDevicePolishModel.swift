import Foundation

/// The small polish model the keyboard runs on the phone: Qwen3.5-0.8B tuned (round three, on fact-checked examples) on
/// dictated and phone-typed notes. The app downloads it into the App Group once,
/// and the keyboard memory-maps it from there.
enum OnDevicePolishModel {
    static let fileName = "qwen3.5-0.8b-r3-Q8_0.gguf"
    static let byteCount = 811_843_232
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
