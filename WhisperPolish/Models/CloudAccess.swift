import Foundation

enum CloudAccessMode: String, CaseIterable, Identifiable {
    case personalKey
    case subscription

    var id: String { rawValue }

    var title: String {
        switch self {
        case .personalKey: return "Personal Key"
        case .subscription: return "Whisper Polish Cloud"
        }
    }
}

enum CloudPlan {
    static let productID = "com.jonclegg.WhisperPolish.cloud.monthly"
    static let monthlyPolishLimit = 300
}

enum AppConfiguration {
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
