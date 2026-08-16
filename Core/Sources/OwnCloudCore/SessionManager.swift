import Foundation

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

    public init(
        store: CredentialStore,
        now: @escaping () -> Date = Date.init,
        leeway: TimeInterval = SessionManager.defaultRefreshLeeway,
        refresh: RefreshHandler? = nil
    ) {
        self.store = store
        self.now = now
        self.leeway = leeway
        self.refresh = refresh
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
    public func refreshTokenIfNeeded() throws {
        guard needsTokenRefresh() else { return }
        guard case let .bearer(_, refreshToken, _) = store.load() else { return }
        guard let refresh else { return }
        let fresh = try refresh(refreshToken)
        store.save(fresh)
    }
}
