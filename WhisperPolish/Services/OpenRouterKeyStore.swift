import Foundation
import Observation
import Security

protocol SecretStoring {
    func read(account: String) throws -> String?
    func write(_ value: String, account: String) throws
    func delete(account: String) throws
}

enum KeychainStoreError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return SecCopyErrorMessageString(status, nil) as String?
                ?? "Keychain operation failed (\(status))."
        case .invalidData:
            return "The saved OpenRouter key could not be read."
        }
    }
}

struct KeychainSecretStore: SecretStoring {
    let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "com.jonclegg.WhisperPolish") {
        self.service = service
    }

    func read(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStoreError.unexpectedStatus(status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.invalidData
        }
        return value
    }

    func write(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addition = query
            addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addition as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainStoreError.unexpectedStatus(addStatus) }
            return
        }
        guard updateStatus == errSecSuccess else { throw KeychainStoreError.unexpectedStatus(updateStatus) }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Owns the user's OpenRouter API key without placing it in UserDefaults.
/// Existing installs are migrated once from the legacy AppStorage value.
@Observable
final class OpenRouterKeyStore {
    static let account = "openrouter-api-key"

    private(set) var value = ""
    private(set) var errorMessage: String?
    private let secrets: any SecretStoring

    init(
        secrets: any SecretStoring = KeychainSecretStore(),
        defaults: UserDefaults = .standard
    ) {
        self.secrets = secrets

        do {
            if let saved = try secrets.read(account: Self.account), !saved.isEmpty {
                value = saved
                defaults.removeObject(forKey: SettingsKeys.openRouterKey)
            } else if let legacy = defaults.string(forKey: SettingsKeys.openRouterKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !legacy.isEmpty {
                try secrets.write(legacy, account: Self.account)
                value = legacy
                defaults.removeObject(forKey: SettingsKeys.openRouterKey)
            } else {
                defaults.removeObject(forKey: SettingsKeys.openRouterKey)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func update(_ newValue: String) throws {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try secrets.delete(account: Self.account)
        } else {
            try secrets.write(trimmed, account: Self.account)
        }
        value = trimmed
        errorMessage = nil
    }
}
