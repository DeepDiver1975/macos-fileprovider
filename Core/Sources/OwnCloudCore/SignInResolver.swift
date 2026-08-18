import Foundation

/// The headless decision layer of the Classic sign-in flow (Task 7.11).
///
/// The settings window collects a server URL, username and password; the Mac-only
/// ``ServerProbing`` adapter turns the URL into a ``BackendProbeResult``. This
/// resolver is the pure step in between: it validates and normalizes the inputs,
/// asks ``BackendDetector`` what kind of server answered, and — for ownCloud
/// Classic — produces the ``AccountDescriptor``, the ``Credentials`` to store, and
/// the ``SyncRoot`` the domain is built from. Keeping every decision here means the
/// SwiftUI sheet stays a thin field-collector and the logic is covered by the
/// Linux-buildable test suite.
///
/// oCIS is deliberately out of scope for this flow (it needs OIDC, not a
/// username/password), so an oCIS server is rejected with a specific error rather
/// than silently mishandled.

/// Why a sign-in attempt could not be turned into an account.
public enum SignInError: Error, Equatable {
    /// The server field was empty (after trimming whitespace).
    case emptyServerURL
    /// The username field was empty (after trimming whitespace).
    case emptyUsername
    /// The server string did not parse into a URL with a host.
    case invalidServerURL
    /// The server answered but is neither a usable Classic nor oCIS server
    /// (`BackendDetector.detect` returned `nil`).
    case backendNotDetected
    /// The server is oCIS, whose OIDC sign-in this flow does not implement yet.
    case ocisNotSupportedYet
}

/// The product of a successful sign-in resolution: everything the caller needs to
/// persist the credential and register the domain.
public struct ResolvedSignIn: Equatable {
    public let account: AccountDescriptor
    public let credentials: Credentials
    public let syncRoot: SyncRoot

    public init(account: AccountDescriptor, credentials: Credentials, syncRoot: SyncRoot) {
        self.account = account
        self.credentials = credentials
        self.syncRoot = syncRoot
    }
}

public enum SignInResolver {

    /// Resolve raw sign-in inputs plus a backend probe into a ``ResolvedSignIn`` or
    /// a ``SignInError``.
    ///
    /// Normalization: leading/trailing whitespace is trimmed from all fields; a
    /// server string with no scheme is treated as plain `http://` (the local
    /// fixture is HTTP). A URL that still lacks a host is rejected.
    public static func resolve(serverURL: String,
                               username: String,
                               password: String,
                               probe: BackendProbeResult) -> Result<ResolvedSignIn, SignInError> {
        let trimmedServer = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedServer.isEmpty else { return .failure(.emptyServerURL) }

        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty else { return .failure(.emptyUsername) }

        // A bare host ("localhost:8080") is treated as plain HTTP for fixture
        // ergonomics; an explicit scheme is left untouched.
        let normalizedString = trimmedServer.contains("://") ? trimmedServer : "http://\(trimmedServer)"
        guard let url = URL(string: normalizedString), url.host != nil else {
            return .failure(.invalidServerURL)
        }

        switch BackendDetector.detect(from: probe) {
        case .none:
            return .failure(.backendNotDetected)
        case .ocis:
            return .failure(.ocisNotSupportedYet)
        case .classic:
            let account = AccountDescriptor(backend: .classic, serverURL: url, username: trimmedUsername)
            // Classic is a single sync root over its files root — no drive id.
            guard let syncRoot = SyncRoot(account: account, driveID: nil) else {
                return .failure(.invalidServerURL)
            }
            return .success(ResolvedSignIn(
                account: account,
                credentials: .basic(username: trimmedUsername, password: password),
                syncRoot: syncRoot))
        }
    }
}
