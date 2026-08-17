import Foundation

/// The two authentication schemes the provider supports, behind one type.
///
/// - `basic`: ownCloud Classic — HTTP Basic with a username and password (or an
///   app password). Never expires from the client's point of view.
/// - `bearer`: oCIS — an OAuth2 / OIDC access token with a refresh token and an
///   absolute expiry.
public enum Credentials: Equatable, Sendable {
    case basic(username: String, password: String)
    case bearer(accessToken: String, refreshToken: String, expiresAt: Date)
}

/// Persistence boundary for `Credentials`. On device this is backed by the
/// shared Keychain access group (progress.md Task 1.3) so the app's sign-in
/// flow and the extension see the same credentials; in tests it is faked.
public protocol CredentialStore: AnyObject {
    func load() -> Credentials?
    func save(_ credentials: Credentials)
    func clear()
}

public enum SessionError: Error, Equatable {
    /// No credentials are stored — the user must sign in.
    case notAuthenticated
}
