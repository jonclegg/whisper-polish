import Foundation

enum CloudPlan {
    static let productID = "com.[REDACTED].WhisperPolish.cloud.monthly"
    static let monthlyPolishLimit = 300
}

enum AppConfiguration {
    /// Dev builds skip the subscription and polish straight through OpenRouter.
    static let isDevMode = Bundle.main.object(forInfoDictionaryKey: "WhisperPolishDevMode") as? String == "YES"

    static var cloudPolishEndpoint: URL? {
        guard let base = Bundle.main.object(forInfoDictionaryKey: "WhisperPolishCloudAPIBaseURL") as? String,
              !base.isEmpty,
              let baseURL = URL(string: base) else { return nil }
        return baseURL.appendingPathComponent("v1/polish")
    }
}

enum CloudConfigurationError: LocalizedError {
    case missingEndpoint

    var errorDescription: String? {
        "Whisper Polish Cloud is not configured in this build."
    }
}
