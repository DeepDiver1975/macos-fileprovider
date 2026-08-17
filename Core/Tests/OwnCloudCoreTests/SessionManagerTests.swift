import XCTest
@testable import OwnCloudCore

/// Task 2.5: unified credential / session manager.
///
/// Two auth schemes behind one interface:
///   - ownCloud Classic → HTTP Basic (username + password/app-password)
///   - oCIS            → OAuth2 / OIDC bearer token with refresh
///
/// The testable surface is the pure logic: which `Authorization` header to
/// produce, and when a bearer token is considered expired and must be
/// refreshed. Keychain persistence sits behind the injectable `CredentialStore`
/// protocol so it can be faked here (real Keychain access needs entitlements /
/// a signed host, per progress.md Task 1.3).
final class SessionManagerTests: XCTestCase {

    // MARK: - Basic auth (Classic)

    func testBasicAuthHeaderIsBase64EncodedCredentials() throws {
        let creds = Credentials.basic(username: "admin", password: "secret")
        let store = InMemoryCredentialStore(initial: creds)
        let manager = SessionManager(store: store, now: { Date(timeIntervalSince1970: 0) })

        let header = try manager.authorizationHeader()

        // base64("admin:secret") == "YWRtaW46c2VjcmV0"
        XCTAssertEqual(header, "Basic YWRtaW46c2VjcmV0")
    }

    func testBasicAuthNeverNeedsRefresh() {
        let store = InMemoryCredentialStore(initial: .basic(username: "u", password: "p"))
        let manager = SessionManager(store: store, now: { Date(timeIntervalSince1970: 1_000_000) })
        XCTAssertFalse(manager.needsTokenRefresh())
    }

    // MARK: - Bearer token (oCIS)

    func testBearerHeaderUsesAccessToken() throws {
        let creds = Credentials.bearer(
            accessToken: "at-123",
            refreshToken: "rt-456",
            expiresAt: Date(timeIntervalSince1970: 3600)
        )
        let store = InMemoryCredentialStore(initial: creds)
        let manager = SessionManager(store: store, now: { Date(timeIntervalSince1970: 0) })

        XCTAssertEqual(try manager.authorizationHeader(), "Bearer at-123")
    }

    func testBearerNeedsRefreshWithinLeewayOfExpiry() {
        // Token expires at t=3600; default leeway is 60s. At t=3550 (<60s left)
        // it must be considered in need of refresh.
        let creds = Credentials.bearer(accessToken: "at", refreshToken: "rt", expiresAt: Date(timeIntervalSince1970: 3600))
        let store = InMemoryCredentialStore(initial: creds)

        let early = SessionManager(store: store, now: { Date(timeIntervalSince1970: 3000) })
        XCTAssertFalse(early.needsTokenRefresh())

        let late = SessionManager(store: store, now: { Date(timeIntervalSince1970: 3550) })
        XCTAssertTrue(late.needsTokenRefresh())
    }

    func testBearerNeedsRefreshWhenExpired() {
        let creds = Credentials.bearer(accessToken: "at", refreshToken: "rt", expiresAt: Date(timeIntervalSince1970: 100))
        let store = InMemoryCredentialStore(initial: creds)
        let manager = SessionManager(store: store, now: { Date(timeIntervalSince1970: 200) })
        XCTAssertTrue(manager.needsTokenRefresh())
    }

    // MARK: - Refresh updates the stored credentials

    func testRefreshReplacesAccessTokenAndPersists() throws {
        let creds = Credentials.bearer(accessToken: "old", refreshToken: "rt-1", expiresAt: Date(timeIntervalSince1970: 100))
        let store = InMemoryCredentialStore(initial: creds)
        var callCount = 0
        let manager = SessionManager(
            store: store,
            now: { Date(timeIntervalSince1970: 200) },
            refresh: { refreshToken in
                callCount += 1
                XCTAssertEqual(refreshToken, "rt-1")
                return .bearer(accessToken: "new", refreshToken: "rt-2", expiresAt: Date(timeIntervalSince1970: 4000))
            }
        )

        try manager.refreshTokenIfNeeded()

        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(try manager.authorizationHeader(), "Bearer new")
        // Persisted back into the store.
        XCTAssertEqual(store.load(), .bearer(accessToken: "new", refreshToken: "rt-2", expiresAt: Date(timeIntervalSince1970: 4000)))
    }

    func testRefreshIsNoOpWhenTokenStillValid() throws {
        let creds = Credentials.bearer(accessToken: "still-good", refreshToken: "rt", expiresAt: Date(timeIntervalSince1970: 9999))
        let store = InMemoryCredentialStore(initial: creds)
        var callCount = 0
        let manager = SessionManager(
            store: store,
            now: { Date(timeIntervalSince1970: 0) },
            refresh: { _ in callCount += 1; return .basic(username: "x", password: "y") }
        )

        try manager.refreshTokenIfNeeded()
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(try manager.authorizationHeader(), "Bearer still-good")
    }

    func testAuthorizationHeaderThrowsWhenNoCredentials() {
        let store = InMemoryCredentialStore(initial: nil)
        let manager = SessionManager(store: store, now: { Date(timeIntervalSince1970: 0) })
        XCTAssertThrowsError(try manager.authorizationHeader()) { error in
            XCTAssertEqual(error as? SessionError, .notAuthenticated)
        }
    }

    func testRefreshWhenBasicAuthIsNoOp() throws {
        let store = InMemoryCredentialStore(initial: .basic(username: "u", password: "p"))
        let manager = SessionManager(store: store, now: { Date(timeIntervalSince1970: 0) }, refresh: { _ in
            XCTFail("basic auth must not trigger refresh")
            return .basic(username: "", password: "")
        })
        try manager.refreshTokenIfNeeded()
    }
}

/// Test double for `CredentialStore`.
private final class InMemoryCredentialStore: CredentialStore {
    private var creds: Credentials?
    init(initial: Credentials?) { self.creds = initial }
    func load() -> Credentials? { creds }
    func save(_ credentials: Credentials) { creds = credentials }
    func clear() { creds = nil }
}
