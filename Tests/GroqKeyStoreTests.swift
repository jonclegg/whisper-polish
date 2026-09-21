import XCTest
@testable import WhisperPolish

final class GroqKeyStoreTests: XCTestCase {
    func testEmptyStoreHasNoKey() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = GroqKeyStore(secrets: MemorySecretStore(), defaults: defaults)

        XCTAssertEqual(store.value, "")
    }

    func testUpdatePersistsTrimmedKeyAndEmptyUpdateDeletesIt() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let secrets = MemorySecretStore()
        let store = GroqKeyStore(secrets: secrets, defaults: defaults)

        try store.update("  gsk-new  ")
        XCTAssertEqual(store.value, "gsk-new")
        XCTAssertEqual(try secrets.read(account: GroqKeyStore.account), "gsk-new")
        XCTAssertNil(try secrets.read(account: OpenRouterKeyStore.account))

        try store.update("   ")
        XCTAssertEqual(store.value, "")
        XCTAssertNil(try secrets.read(account: GroqKeyStore.account))
    }

    func testOpenRouterAndGroqKeysDoNotOverwriteEachOther() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let secrets = MemorySecretStore()
        let openRouter = OpenRouterKeyStore(secrets: secrets, defaults: defaults)
        let groq = GroqKeyStore(secrets: secrets, defaults: defaults)

        try openRouter.update("sk-or-one")
        try groq.update("gsk-two")

        XCTAssertEqual(openRouter.value, "sk-or-one")
        XCTAssertEqual(groq.value, "gsk-two")
        XCTAssertEqual(try secrets.read(account: OpenRouterKeyStore.account), "sk-or-one")
        XCTAssertEqual(try secrets.read(account: GroqKeyStore.account), "gsk-two")
    }
}
