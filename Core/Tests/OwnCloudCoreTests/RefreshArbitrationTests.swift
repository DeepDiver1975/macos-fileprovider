import XCTest
@testable import OwnCloudCore

/// Task 7.6: credential-refresh arbitration. The per-space domain model means N
/// extension instances each hold a `SessionManager` over the *same* Keychain item.
/// oCIS/Keycloak rotate the refresh token on use, so the first instance to refresh
/// invalidates the token the other N−1 hold — signing every space but one out.
///
/// The fix is cross-process double-checked locking: take an exclusive lock,
/// **re-read** the item, and refresh only if it is *still* stale — so losers pick
/// up the winner's freshly-written token instead of racing to rotate it again.
/// Plus a retry: on any refresh failure, re-read once before surfacing
/// `.notAuthenticated`, because the failure may just mean a winner beat us to it.
final class RefreshArbitrationTests: XCTestCase {

    private let stale = Credentials.bearer(
        accessToken: "old", refreshToken: "rt-1", expiresAt: Date(timeIntervalSince1970: 100))
    private let fresh = Credentials.bearer(
        accessToken: "winner", refreshToken: "rt-2", expiresAt: Date(timeIntervalSince1970: 4000))
    private let now = { Date(timeIntervalSince1970: 200) }   // past the stale expiry

    // MARK: - Double-checked: the loser adopts the winner's token, never refreshes

    func testLoserAdoptsWinnersTokenWithoutRefreshing() throws {
        let store = InMemoryCredentialStore(initial: stale)
        // The lock stands in for "another instance already refreshed": while we
        // wait for it, the winner writes a fresh token into the shared store.
        let lock = FakeRefreshLock(beforeBody: { store.save(self.fresh) })
        var refreshCalls = 0
        let manager = SessionManager(
            store: store, now: now,
            refresh: { _ in refreshCalls += 1; return self.fresh },
            refreshLock: lock)

        try manager.refreshTokenIfNeeded()

        XCTAssertEqual(refreshCalls, 0, "the re-read inside the lock shows a fresh token, so no rotation")
        XCTAssertEqual(try manager.authorizationHeader(), "Bearer winner")
    }

    // MARK: - The winner refreshes under the lock

    func testWinnerRefreshesUnderTheLock() throws {
        let store = InMemoryCredentialStore(initial: stale)
        let lock = FakeRefreshLock()
        var refreshCalls = 0
        let manager = SessionManager(
            store: store, now: now,
            refresh: { token in
                refreshCalls += 1
                XCTAssertEqual(token, "rt-1")
                return self.fresh
            },
            refreshLock: lock)

        try manager.refreshTokenIfNeeded()

        XCTAssertEqual(refreshCalls, 1)
        XCTAssertTrue(lock.wasHeldDuringBody, "the refresh must run while holding the lock")
        XCTAssertEqual(store.load(), fresh)
    }

    // MARK: - Retry: a failed refresh re-reads once and adopts a winner's token

    func testFailedRefreshAdoptsAConcurrentlyWrittenTokenInsteadOfThrowing() throws {
        let store = InMemoryCredentialStore(initial: stale)
        let lock = FakeRefreshLock()
        let manager = SessionManager(
            store: store, now: now,
            refresh: { _ in
                // Our rotation lost the race and the server rejected our now-stale
                // refresh token — but a winner has already written a fresh one.
                store.save(self.fresh)
                throw SessionError.notAuthenticated
            },
            refreshLock: lock)

        XCTAssertNoThrow(try manager.refreshTokenIfNeeded())
        XCTAssertEqual(try manager.authorizationHeader(), "Bearer winner")
    }

    func testFailedRefreshWithNoWinnerSurfacesNotAuthenticated() throws {
        let store = InMemoryCredentialStore(initial: stale)
        let lock = FakeRefreshLock()
        let manager = SessionManager(
            store: store, now: now,
            refresh: { _ in throw SessionError.notAuthenticated },
            refreshLock: lock)

        XCTAssertThrowsError(try manager.refreshTokenIfNeeded()) { error in
            XCTAssertEqual(error as? SessionError, .notAuthenticated)
        }
    }

    // MARK: - Backward compatibility: no lock behaves as before

    func testNoLockConfiguredStillRefreshesDirectly() throws {
        let store = InMemoryCredentialStore(initial: stale)
        var refreshCalls = 0
        let manager = SessionManager(
            store: store, now: now,
            refresh: { _ in refreshCalls += 1; return self.fresh })

        try manager.refreshTokenIfNeeded()

        XCTAssertEqual(refreshCalls, 1)
        XCTAssertEqual(store.load(), fresh)
    }
}

/// Test double for the refresh lock. Optionally runs `beforeBody` (simulating
/// another instance mutating the shared store while we "wait" for the lock) and
/// records that the body ran inside the lock.
private final class FakeRefreshLock: RefreshLock {
    private let beforeBody: (() -> Void)?
    private(set) var wasHeldDuringBody = false

    init(beforeBody: (() -> Void)? = nil) {
        self.beforeBody = beforeBody
    }

    func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        beforeBody?()
        // Latch that the body ran while we held the lock — the winner's refresh
        // must happen inside this scope, never before or after.
        wasHeldDuringBody = true
        return try body()
    }
}

/// Test double for `CredentialStore` (mirrors the one in SessionManagerTests).
private final class InMemoryCredentialStore: CredentialStore {
    private var creds: Credentials?
    init(initial: Credentials?) { self.creds = initial }
    func load() -> Credentials? { creds }
    func save(_ credentials: Credentials) { creds = credentials }
    func clear() { creds = nil }
}
