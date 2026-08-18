import Foundation

/// Serializes credential refresh across processes (Task 7.6). The production
/// conformer is a `flock` over a file in the app group container (``FileLock``);
/// tests inject a fake. When no lock is configured a refresh runs directly, which
/// is correct for the single-instance app and for Basic auth.
public protocol RefreshLock: Sendable {
    /// Run `body` while holding the exclusive lock, blocking until available.
    func withExclusiveLock<T>(_ body: () throws -> T) throws -> T
}

/// Unified credential / session manager (progress.md Task 2.5).
///
/// Produces the `Authorization` header for whichever scheme is stored, and — for
/// bearer tokens — decides when a refresh is due and performs it, persisting the
/// new credentials. `now` and `refresh` are injected so the expiry logic is
/// deterministically testable without a clock or a live OIDC endpoint.
public final class SessionManager {

    /// How long before a bearer token's expiry it is already treated as stale,
    /// so a refresh happens before requests start failing with 401.
    public static let defaultRefreshLeeway: TimeInterval = 60

    /// Performs the OAuth2 refresh-token grant, returning fresh credentials.
    /// Injected so tests need no network; the production wiring calls the OIDC
    /// token endpoint.
    public typealias RefreshHandler = (_ refreshToken: String) throws -> Credentials

    private let store: CredentialStore
    private let now: () -> Date
    private let leeway: TimeInterval
    private let refresh: RefreshHandler?
    private let refreshLock: RefreshLock?

    public init(
        store: CredentialStore,
        now: @escaping () -> Date = Date.init,
        leeway: TimeInterval = SessionManager.defaultRefreshLeeway,
        refresh: RefreshHandler? = nil,
        refreshLock: RefreshLock? = nil
    ) {
        self.store = store
        self.now = now
        self.leeway = leeway
        self.refresh = refresh
        self.refreshLock = refreshLock
    }

    /// The `Authorization` header value for the current credentials.
    public func authorizationHeader() throws -> String {
        guard let credentials = store.load() else {
            throw SessionError.notAuthenticated
        }
        switch credentials {
        case let .basic(username, password):
            let raw = "\(username):\(password)"
            let encoded = Data(raw.utf8).base64EncodedString()
            return "Basic \(encoded)"
        case let .bearer(accessToken, _, _):
            return "Bearer \(accessToken)"
        }
    }

    /// `true` when a stored bearer token is within `leeway` of expiry (or past
    /// it). Basic auth and the unauthenticated state never need a refresh.
    public func needsTokenRefresh() -> Bool {
        guard case let .bearer(_, _, expiresAt) = store.load() else {
            return false
        }
        return now().addingTimeInterval(leeway) >= expiresAt
    }

    /// Refreshes the bearer token if it is due, persisting the result. No-op for
    /// basic auth, when no refresh handler is configured, or when still valid.
    ///
    /// Cross-process arbitration (Task 7.6): with a ``RefreshLock`` configured the
    /// decision is made **under the lock** with a fresh read — so N instances
    /// sharing one Keychain item do not each rotate the token and sign each other
    /// out. The first instance in refreshes; the rest re-read, see a valid token,
    /// and adopt it. On a refresh *failure* the item is re-read once before the
    /// error is surfaced: the failure may just mean a winner beat us to it and
    /// invalidated the token we tried to rotate.
    public func refreshTokenIfNeeded() throws {
        guard needsTokenRefresh() else { return }
        guard let refresh else { return }

        guard let refreshLock else {
            // Single-instance / no arbitration: refresh directly.
            try performRefresh(refresh)
            return
        }
        try refreshLock.withExclusiveLock {
            // Double-check: a winner may have refreshed while we waited for the lock.
            guard needsTokenRefresh() else { return }
            do {
                try performRefresh(refresh)
            } catch {
                // Retry the decision once against the current item — a concurrent
                // winner may have written a fresh token our failed rotation raced.
                guard needsTokenRefresh() else { return }
                throw error
            }
        }
    }

    /// Read the current refresh token, run the handler, and persist the result.
    /// A no-op if the stored credential is not a bearer token.
    private func performRefresh(_ refresh: RefreshHandler) throws {
        guard case let .bearer(_, refreshToken, _) = store.load() else { return }
        let fresh = try refresh(refreshToken)
        store.save(fresh)
    }
}
