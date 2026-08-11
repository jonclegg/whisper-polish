import XCTest
@testable import WhisperPolish

final class OpenRouterKeyStoreTests: XCTestCase {
    func testMigratesLegacyUserDefaultsKeyIntoSecretStore() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set("sk-or-legacy", forKey: SettingsKeys.openRouterKey)
        let secrets = MemorySecretStore()

        let store = OpenRouterKeyStore(secrets: secrets, defaults: defaults)

        XCTAssertEqual(store.value, "sk-or-legacy")
        XCTAssertEqual(try secrets.read(account: OpenRouterKeyStore.account), "sk-or-legacy")
        XCTAssertNil(defaults.string(forKey: SettingsKeys.openRouterKey))
    }

    func testExistingKeychainValueWinsOverLegacyDefaults() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set("sk-or-legacy", forKey: SettingsKeys.openRouterKey)
        let secrets = MemorySecretStore(values: [OpenRouterKeyStore.account: "sk-or-current"])

        let store = OpenRouterKeyStore(secrets: secrets, defaults: defaults)

        XCTAssertEqual(store.value, "sk-or-current")
        XCTAssertNil(defaults.string(forKey: SettingsKeys.openRouterKey))
    }

    func testUpdatePersistsTrimmedKeyAndEmptyUpdateDeletesIt() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let secrets = MemorySecretStore()
        let store = OpenRouterKeyStore(secrets: secrets, defaults: defaults)

        try store.update("  sk-or-new  ")
        XCTAssertEqual(store.value, "sk-or-new")
        XCTAssertEqual(try secrets.read(account: OpenRouterKeyStore.account), "sk-or-new")

        try store.update("   ")
        XCTAssertEqual(store.value, "")
        XCTAssertNil(try secrets.read(account: OpenRouterKeyStore.account))
    }
}

private final class MemorySecretStore: SecretStoring {
    private var values: [String: String]

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func read(account: String) throws -> String? {
        values[account]
    }

    func write(_ value: String, account: String) throws {
        values[account] = value
    }

    func delete(account: String) throws {
        values.removeValue(forKey: account)
    }
}
