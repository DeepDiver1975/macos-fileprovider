import Foundation

/// Why an oCIS OIDC sign-in could not be turned into an account (Task 7.12).
public enum OCISSignInError: Error, Equatable {
    /// The credentials handed in were not `.bearer` — an OIDC sign-in must yield a
    /// bearer token, never Basic auth.
    case notBearerCredentials
    /// The `me/drives` listing was empty, so there is no space to sync and no domain
    /// could be created.
    case noSpaces
}

/// The product of a successful oCIS sign-in resolution: the account identity, the
/// bearer credential to store, one sync root per space, and the catalog the Spaces
/// tab renders.
public struct ResolvedOCISSignIn: Equatable {
    public let account: AccountDescriptor
    public let credentials: Credentials
    public let syncRoots: [SyncRoot]
    public let catalog: SpaceCatalog

    public init(account: AccountDescriptor, credentials: Credentials, syncRoots: [SyncRoot], catalog: SpaceCatalog) {
        self.account = account
        self.credentials = credentials
        self.syncRoots = syncRoots
        self.catalog = catalog
    }
}

/// The headless decision layer of the oCIS OIDC sign-in flow — the counterpart of
/// ``SignInResolver`` for Infinite Scale.
///
/// ``OIDCSignInCoordinator`` produces the bearer credential and the `id_token`; the
/// Mac networking layer then fetches `me/drives`. This resolver is the pure step in
/// between: it names the account from the `id_token` claims (there is no typed
/// username in an OIDC flow), verifies the credential kind, and maps every drive to
/// a ``SyncRoot`` so the domain lifecycle can create one domain per space. Keeping
/// it here means the SwiftUI sheet stays a thin field-collector and the logic is
/// covered by the Linux-buildable suite.
public enum OCISSignInResolver {

    /// Resolve a completed oCIS sign-in into a ``ResolvedOCISSignIn``.
    ///
    /// - Parameters:
    ///   - serverURL: the signed-in server.
    ///   - credentials: the ``OIDCSignInCoordinator`` result; must be `.bearer`.
    ///   - idToken: the raw `id_token` JWT, parsed for the account name.
    ///   - drives: the `me/drives` listing (already fetched by the Mac layer).
    /// - Throws: ``OCISSignInError`` on the wrong credential kind or no spaces, or
    ///   ``OIDCIDTokenError`` if the `id_token` is unparseable.
    public static func resolve(serverURL: URL,
                               credentials: Credentials,
                               idToken: String,
                               drives: [GraphDrive]) throws -> ResolvedOCISSignIn {
        guard case .bearer = credentials else {
            throw OCISSignInError.notBearerCredentials
        }
        guard !drives.isEmpty else {
            throw OCISSignInError.noSpaces
        }

        let claims = try OIDCIDToken.claims(from: idToken)
        let account = AccountDescriptor(backend: .ocis, serverURL: serverURL, username: claims.accountName)

        // One sync root per drive, preserving listing order. An oCIS drive id never
        // carries the reserved `|`, so `SyncRoot.init` never fails here — but drop
        // any that somehow did rather than force-unwrapping.
        let syncRoots = drives.compactMap { SyncRoot(account: account, driveID: $0.id) }

        return ResolvedOCISSignIn(
            account: account,
            credentials: credentials,
            syncRoots: syncRoots,
            catalog: SpaceCatalog(drives: drives))
    }
}
