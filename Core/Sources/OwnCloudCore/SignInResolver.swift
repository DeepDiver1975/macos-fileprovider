import Foundation

/// The headless decision layer of the sign-in flow (Task 7.11, issue #17).
///
/// The settings window collects a server URL; the Mac-only ``ServerProbing`` adapter
/// turns it into a ``BackendProbeResult``. This resolver is the pure step in between,
/// in the two steps the sheet can actually take:
///
/// 1. ``route(serverURL:probe:)`` validates and normalizes the server, asks
///    ``BackendDetector`` what kind of server answered, and says which sign-in it
///    calls for. For oCIS that is all there is to decide — the identity lives in an
///    `id_token` that only exists after the browser flow, so
///    ``OIDCSignInCoordinator`` takes it from here.
/// 2. ``resolveClassic(serverURL:username:password:)`` finishes a Classic sign-in
///    once the credentials that step asked for exist, producing the
///    ``AccountDescriptor``, the ``Credentials`` to store, and the ``SyncRoot`` the
///    domain is built from.
///
/// Keeping every decision here means the SwiftUI sheet stays a thin field-collector
/// and the logic is covered by the Linux-buildable test suite.

/// Why a sign-in attempt could not be turned into an account.
public enum SignInError: Error, Equatable {
    /// The server field was empty (after trimming whitespace).
    case emptyServerURL
    /// The username field was empty (after trimming whitespace). Classic only — an
    /// OIDC sign-in has no typed username.
    case emptyUsername
    /// The server string did not parse into a URL with a host.
    case invalidServerURL
    /// The server answered but is neither a usable Classic nor oCIS server
    /// (`BackendDetector.detect` returned `nil`).
    case backendNotDetected
}

/// Which sign-in the probed server calls for. Both cases carry the *normalized*
/// server URL, so whoever continues the flow uses the same URL that was probed.
public enum SignInRoute: Sendable, Equatable {
    /// ownCloud Classic: collect a username and password, then finish with
    /// ``SignInResolver/resolveClassic(serverURL:username:password:)``.
    case classic(serverURL: URL)
    /// oCIS: run the OIDC Authorization-Code flow against this server. No account
    /// can be resolved yet — the identity is in the `id_token`.
    case oidc(serverURL: URL)
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

    /// Decide which sign-in a probed server calls for — the first step, taking the
    /// server field and nothing else.
    ///
    /// It takes nothing else because nothing else has been typed yet: an oCIS
    /// sign-in never has a username (the identity is in the `id_token`), and a
    /// Classic one has not been asked for one until this step says to.
    ///
    /// Normalization: leading/trailing whitespace is trimmed; a server string with no
    /// scheme is treated as plain `http://` (the local fixture is HTTP). A URL that
    /// still lacks a host is rejected. The normalized URL is what the route carries,
    /// so the continuation uses the URL that was actually probed.
    public static func route(serverURL: String,
                             probe: BackendProbeResult) -> Result<SignInRoute, SignInError> {
        let trimmedServer = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedServer.isEmpty else { return .failure(.emptyServerURL) }

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
            return .success(.oidc(serverURL: url))
        case .classic:
            return .success(.classic(serverURL: url))
        }
    }

    /// Finish a Classic sign-in with the credentials the ``SignInRoute/classic``
    /// step collected: the account identity, the Basic credential to store, and the
    /// single sync root its domain is built from.
    ///
    /// `serverURL` is the already-normalized URL from the route, so it is not
    /// re-parsed. The username is required here — it is the Basic-auth identity —
    /// and is trimmed so it matches the identity the Keychain item is keyed by. The
    /// password is passed through verbatim: trimming it would silently change a
    /// legitimate secret, and an empty one is the server's to reject.
    public static func resolveClassic(serverURL: URL,
                                      username: String,
                                      password: String) -> Result<ResolvedSignIn, SignInError> {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty else { return .failure(.emptyUsername) }

        let account = AccountDescriptor(backend: .classic, serverURL: serverURL, username: trimmedUsername)
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
