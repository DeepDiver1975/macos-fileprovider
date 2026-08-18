import XCTest
@testable import OwnCloudCore

/// Task 7.3: the account registry. Credentials live in the Keychain; the registry
/// is the small list of *which accounts exist* — it exists for exactly one reason:
/// an account with **zero** spaces selected has no domains and would otherwise
/// vanish. It is stored as one JSON blob under one key in an injectable
/// key-value store (the app group `UserDefaults` in production, a fake in tests).
final class AccountRegistryTests: XCTestCase {

    private let einstein = AccountRecord(
        accountIdentifier: "ocis|https%3A%2F%2Focis.test|einstein",
        backend: .ocis,
        serverURL: URL(string: "https://ocis.test")!,
        username: "einstein"
    )
    private let admin = AccountRecord(
        accountIdentifier: "classic|http%3A%2F%2Flocalhost%3A8080|admin",
        backend: .classic,
        serverURL: URL(string: "http://localhost:8080")!,
        username: "admin"
    )

    // MARK: - Round trip

    func testUpsertAndLoadRoundTrips() {
        let store = InMemoryKeyValueStore()
        let registry = AccountRegistry(store: store)

        registry.upsert(einstein)
        registry.upsert(admin)

        let reloaded = AccountRegistry(store: store)
        XCTAssertEqual(Set(reloaded.accounts), Set([einstein, admin]))
    }

    func testUpsertReplacesAnAccountWithTheSameIdentifier() {
        let store = InMemoryKeyValueStore()
        let registry = AccountRegistry(store: store)
        registry.upsert(einstein)

        // Same identifier, changed username casing — replaces, does not duplicate.
        let renamed = AccountRecord(
            accountIdentifier: einstein.accountIdentifier,
            backend: .ocis, serverURL: einstein.serverURL, username: "Einstein")
        registry.upsert(renamed)

        XCTAssertEqual(registry.accounts.count, 1)
        XCTAssertEqual(registry.accounts.first?.username, "Einstein")
    }

    func testRemoveDeletesOnlyTheNamedAccount() {
        let store = InMemoryKeyValueStore()
        let registry = AccountRegistry(store: store)
        registry.upsert(einstein)
        registry.upsert(admin)

        registry.remove(accountIdentifier: einstein.accountIdentifier)

        XCTAssertEqual(registry.accounts, [admin])
    }

    // MARK: - Defaults and corruption

    func testAbsentKeyReadsAsEmpty() {
        let registry = AccountRegistry(store: InMemoryKeyValueStore())
        XCTAssertEqual(registry.accounts, [])
    }

    func testCorruptBlobReadsAsEmpty() {
        // The posture KeychainCredentialStoreTests already sets: a blob that no
        // longer decodes is treated as "no accounts" rather than crashing.
        let store = InMemoryKeyValueStore()
        store.setData(Data("not json".utf8), forKey: AccountRegistry.storageKey)
        let registry = AccountRegistry(store: store)
        XCTAssertEqual(registry.accounts, [])
        // And a subsequent upsert recovers cleanly, overwriting the garbage.
        registry.upsert(admin)
        XCTAssertEqual(registry.accounts, [admin])
    }

    // MARK: - Space-catalog cache (display-only, never authoritative)

    func testSpaceCatalogCacheRoundTrips() {
        let store = InMemoryKeyValueStore()
        let cache = SpaceCatalogCache(store: store)
        let catalog = SpaceCatalog(spaces: [
            Space(driveID: "d1", name: "Personal", driveType: "personal", quotaTotal: 100, quotaUsed: 10),
        ])

        cache.store(catalog, forAccount: einstein.accountIdentifier)

        let reloaded = SpaceCatalogCache(store: store).catalog(forAccount: einstein.accountIdentifier)
        XCTAssertEqual(reloaded, catalog)
    }

    func testSpaceCatalogCacheMissReturnsNil() {
        let cache = SpaceCatalogCache(store: InMemoryKeyValueStore())
        XCTAssertNil(cache.catalog(forAccount: "never-cached"))
    }
}

/// A test double for the ``KeyValueStore`` seam.
private final class InMemoryKeyValueStore: KeyValueStore {
    private var storage: [String: Data] = [:]
    func data(forKey key: String) -> Data? { storage[key] }
    func setData(_ data: Data?, forKey key: String) { storage[key] = data }
}
