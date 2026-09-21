import Foundation
import Observation

/// Owns the user's Groq API key without placing it in UserDefaults.
@Observable
final class GroqKeyStore {
    static let account = "groq-api-key"

    private(set) var value = ""
    private(set) var errorMessage: String?
    private let secrets: any SecretStoring

    init(
        secrets: any SecretStoring = KeychainSecretStore(),
        defaults: UserDefaults = .standard
    ) {
        self.secrets = secrets
        do {
            value = try APIKeyPersistence.load(
                account: Self.account,
                secrets: secrets,
                defaults: defaults
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func update(_ newValue: String) throws {
        value = try APIKeyPersistence.update(newValue, account: Self.account, secrets: secrets)
        errorMessage = nil
    }
}
