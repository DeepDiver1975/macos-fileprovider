#if canImport(Security)
import XCTest
@testable import FileProviderSupport
@testable import OwnCloudCore

/// `KeychainCredentialStore` is the concrete ``CredentialStore`` the app's
/// sign-in flow and the extension share via the Keychain access group
/// (progress.md Task 1.3 / 2.5). The real `SecItem` calls need a signed, entitled
/// host, so the store talks to an injectable ``KeychainBackend``; here that seam
/// is faked in memory. What's verified headlessly: it encodes/decodes via
/// ``CredentialCoder``, addresses the item by the account's stable identifier
/// under the shared access group, overwrites on re-save, and clears.
final class KeychainCredentialStoreTests: XCTestCase {

    /// In-memory stand-in for the `SecItem` keychain, keyed like the real one.
    private final class FakeKeychainBackend: KeychainBackend {
        struct Key: Hashable { let service: String; let account: String; let accessGroup: String? }
        private(set) var items: [Key: Data] = [:]

        func loadData(service: String, account: String, accessGroup: String?) -> Data? {
            items[Key(service: service, account: account, accessGroup: accessGroup)]
        }
        func saveData(_ data: Data, service: String, account: String, accessGroup: String?) {
            items[Key(service: service, account: account, accessGroup: accessGroup)] = data
        }
        func deleteData(service: String, account: String, accessGroup: String?) {
            items[Key(service: service, account: account, accessGroup: accessGroup)] = nil
        }
    }

    private let account = AccountDescriptor(
        backend: .classic,
        serverURL: URL(string: "https://cloud.test")!,
        username: "admin"
    )

    func testSaveThenLoadRoundTripsCredentials() {
        let backend = FakeKeychainBackend()
        let store = KeychainCredentialStore(account: account, accessGroup: "grp", backend: backend)
        let creds = Credentials.basic(username: "admin", password: "secret")

        store.save(creds)

        XCTAssertEqual(store.load(), creds)
    }

    func testLoadReturnsNilWhenNothingStored() {
        let store = KeychainCredentialStore(account: account, accessGroup: "grp", backend: FakeKeychainBackend())

        XCTAssertNil(store.load())
    }

    func testItemIsAddressedByAccountIdentifierAndAccessGroup() {
        let backend = FakeKeychainBackend()
        let store = KeychainCredentialStore(account: account, accessGroup: "grp", backend: backend)

        store.save(.basic(username: "admin", password: "secret"))

        // The single stored item is keyed by the account's stable identifier and
        // the shared access group, so the extension resolves the same item.
        let key = try? XCTUnwrap(backend.items.keys.first)
        XCTAssertEqual(backend.items.count, 1)
        XCTAssertEqual(key?.account, account.accountIdentifier)
        XCTAssertEqual(key?.accessGroup, "grp")
    }

    func testSaveOverwritesPreviousCredentials() {
        let backend = FakeKeychainBackend()
        let store = KeychainCredentialStore(account: account, accessGroup: "grp", backend: backend)

        store.save(.basic(username: "admin", password: "old"))
        store.save(.basic(username: "admin", password: "new"))

        XCTAssertEqual(backend.items.count, 1)
        XCTAssertEqual(store.load(), .basic(username: "admin", password: "new"))
    }

    func testClearRemovesCredentials() {
        let backend = FakeKeychainBackend()
        let store = KeychainCredentialStore(account: account, accessGroup: "grp", backend: backend)
        store.save(.basic(username: "admin", password: "secret"))

        store.clear()

        XCTAssertNil(store.load())
    }

    func testLoadReturnsNilWhenStoredBytesAreCorrupt() {
        let backend = FakeKeychainBackend()
        let store = KeychainCredentialStore(account: account, accessGroup: "grp", backend: backend)
        // Simulate a stored blob that isn't a valid credential payload.
        backend.saveData(Data("garbage".utf8), service: KeychainCredentialStore.service,
                         account: account.accountIdentifier, accessGroup: "grp")

        XCTAssertNil(store.load())
    }

    func testBearerCredentialsRoundTrip() {
        let backend = FakeKeychainBackend()
        let store = KeychainCredentialStore(account: account, accessGroup: "grp", backend: backend)
        let creds = Credentials.bearer(accessToken: "at", refreshToken: "rt",
                                       expiresAt: Date(timeIntervalSince1970: 1_700_000_000))

        store.save(creds)

        XCTAssertEqual(store.load(), creds)
    }
}
#endif
