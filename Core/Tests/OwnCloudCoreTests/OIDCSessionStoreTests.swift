import XCTest
@testable import OwnCloudCore

/// Issue #17 / the Task 2.5 remainder: what the *extension* needs in order to renew
/// an oCIS access token.
///
/// The app performs the sign-in and knows the token endpoint (from discovery), the
/// client id and its secret, and the scope. The extension is a separate process that
/// never ran discovery, so without a record of those it can only use the access token
/// until it expires — five minutes, after which the domain stops working. This store
/// is that record: written by the app at sign-in, read by the extension, over the same
/// app-group ``KeyValueStore`` seam the registry and catalog cache already use.
///
/// Tokens are **not** in here — they stay in the Keychain. This holds only the
/// parameters of the refresh request.
final class OIDCSessionStoreTests: XCTestCase {

    private let accountIdentifier = "ocis|https%3A%2F%2Focis.test|einstein"

    private func record() -> OIDCSessionRecord {
        OIDCSessionRecord(
            tokenEndpoint: URL(string: "https://ocis.test/idp/token")!,
            clientID: "client",
            clientSecret: "secret",
            scope: "openid offline_access")
    }

    func testRoundTripsThroughTheStore() {
        let store = FakeKeyValueStore()
        OIDCSessionStore(store: store).store(record(), forAccount: accountIdentifier)

        let reloaded = OIDCSessionStore(store: store).record(forAccount: accountIdentifier)
        XCTAssertEqual(reloaded, record())
    }

    /// A Classic account never has a record, and that must read as "no refresh
    /// available" rather than as an error — the extension keeps its Basic-auth path.
    func testMissReturnsNil() {
        XCTAssertNil(OIDCSessionStore(store: FakeKeyValueStore()).record(forAccount: "unknown"))
    }

    /// The same tolerant posture as `AccountRegistry` and `KeychainCredentialStore`:
    /// an undecodable blob reads as absent instead of crashing the extension.
    func testCorruptBlobReadsAsNil() {
        let store = FakeKeyValueStore()
        let session = OIDCSessionStore(store: store)
        session.store(record(), forAccount: accountIdentifier)
        // Overwrite the stored blob with garbage under whatever key it used.
        for key in store.keys {
            store.setData(Data("not json".utf8), forKey: key)
        }
        XCTAssertNil(OIDCSessionStore(store: store).record(forAccount: accountIdentifier))
    }

    /// Records are per-account, so two signed-in servers do not overwrite each other.
    func testRecordsAreKeyedPerAccount() {
        let store = FakeKeyValueStore()
        let session = OIDCSessionStore(store: store)
        let other = OIDCSessionRecord(
            tokenEndpoint: URL(string: "https://other.test/token")!,
            clientID: "c2", clientSecret: nil, scope: nil)

        session.store(record(), forAccount: accountIdentifier)
        session.store(other, forAccount: "ocis|https%3A%2F%2Fother.test|bob")

        XCTAssertEqual(session.record(forAccount: accountIdentifier), record())
        XCTAssertEqual(session.record(forAccount: "ocis|https%3A%2F%2Fother.test|bob"), other)
    }

    /// Signing out deletes the record; leaving it behind would let a later account
    /// with the same identifier inherit stale refresh parameters.
    func testRemoveDeletesTheRecord() {
        let store = FakeKeyValueStore()
        let session = OIDCSessionStore(store: store)
        session.store(record(), forAccount: accountIdentifier)

        session.remove(forAccount: accountIdentifier)

        XCTAssertNil(session.record(forAccount: accountIdentifier))
    }

    /// A secret-less public client is representable — the record must not force one.
    func testSecretlessClientRoundTrips() {
        let store = FakeKeyValueStore()
        let session = OIDCSessionStore(store: store)
        let public_ = OIDCSessionRecord(
            tokenEndpoint: URL(string: "https://ocis.test/idp/token")!,
            clientID: "web", clientSecret: nil, scope: "openid")

        session.store(public_, forAccount: accountIdentifier)

        XCTAssertEqual(session.record(forAccount: accountIdentifier)?.clientSecret, nil)
    }
}

/// A test double for the ``KeyValueStore`` seam that also exposes its keys, so the
/// corruption case can overwrite whatever key the store chose.
private final class FakeKeyValueStore: KeyValueStore {
    private var storage: [String: Data] = [:]
    var keys: [String] { Array(storage.keys) }
    func data(forKey key: String) -> Data? { storage[key] }
    func setData(_ data: Data?, forKey key: String) { storage[key] = data }
}
