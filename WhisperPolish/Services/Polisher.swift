import Foundation

/// The one polish entry point for the app and the keyboard.
enum Polisher {
    /// Cloud polish caps each field at 8,000 UTF-8 bytes; image text past this is dropped.
    static let maxContextBytes = 6_000

    /// Returns the rewrite plus the plan usage for cloud polishes. `context`
    /// is text read from an attached image; clean-up ignores it.
    static func polish(text: String, style: PolishStyle, context: String? = nil, transactionJWS: String?) async throws -> (result: PolishResult, usage: CloudUsage?) {
        let context = style.id == PolishStyle.cleanup.id ? nil : trimmedContext(context)
        if AppConfiguration.isDevMode {
            if style.id == PolishStyle.cleanup.id {
                let groqKey = AppConfiguration.devGroqKey
                if groqKey.isEmpty {
                    return (try await PolishService().cleanUpWithOpenRouter(text: text, model: .default, apiKey: AppConfiguration.devOpenRouterKey), nil)
                }
                return (try await PolishService().cleanUpWithGroq(text: text, apiKey: groqKey), nil)
            }
            let result = try await PolishService().polish(text: text, style: style, model: .default, apiKey: AppConfiguration.devOpenRouterKey, context: context)
            return (result, nil)
        }
        guard let endpoint = AppConfiguration.cloudPolishEndpoint else {
            throw CloudConfigurationError.missingEndpoint
        }
        let cloud = try await CloudPolishService(endpoint: endpoint).polish(
            text: text,
            style: style,
            context: context,
            transactionJWS: transactionJWS ?? ""
        )
        return (cloud.polishResult(style: style), cloud.usage)
    }

    static func trimmedContext(_ context: String?) -> String? {
        guard let context = context?.trimmingCharacters(in: .whitespacesAndNewlines), !context.isEmpty else { return nil }
        var bytes = 0
        return String(context.prefix { character in
            bytes += character.utf8.count
            return bytes <= maxContextBytes
        })
    }
}
