import Foundation

enum CloudPlan {
    static let productID = "com.[REDACTED].WhisperPolish.cloud.monthly"
    static let monthlyPolishLimit = 300
}

enum AppConfiguration {
    /// Dev builds skip the subscription and polish straight through the provider.
    static let isDevMode = Bundle.main.object(forInfoDictionaryKey: "WhisperPolishDevMode") as? String == "YES"
    /// Injected at build time for dev builds only; never committed.
    static var devOpenRouterKey: String {
        resolvedDevKey("WhisperPolishDevOpenRouterKey")
    }
    static var devGroqKey: String {
        resolvedDevKey("WhisperPolishDevGroqKey")
    }

    private static func resolvedDevKey(_ key: String) -> String {
        let value = Bundle.main.object(forInfoDictionaryKey: key) as! String
        if value.hasPrefix("$("), value.hasSuffix(")") { return "" }
        return value
    }

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
