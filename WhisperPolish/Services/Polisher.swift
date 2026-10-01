import Foundation

/// The one polish entry point for the app and the keyboard.
enum Polisher {
    /// Returns the rewrite plus the plan usage for cloud polishes.
    static func polish(text: String, style: PolishStyle, transactionJWS: String?) async throws -> (result: PolishResult, usage: CloudUsage?) {
        if AppConfiguration.isDevMode {
            let result = try await PolishService().polish(text: text, style: style, model: .default, apiKey: AppConfiguration.devOpenRouterKey)
            return (result, nil)
        }
        guard let endpoint = AppConfiguration.cloudPolishEndpoint else {
            throw CloudConfigurationError.missingEndpoint
        }
        let cloud = try await CloudPolishService(endpoint: endpoint).polish(
            text: text,
            style: style,
            transactionJWS: transactionJWS ?? ""
        )
        return (cloud.polishResult(style: style), cloud.usage)
    }
}
