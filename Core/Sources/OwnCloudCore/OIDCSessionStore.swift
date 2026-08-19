import Foundation

/// What the File Provider extension needs in order to renew an oCIS access token
/// (issue #17; the refresh half of Task 2.5).
///
/// oCIS issues access tokens with `expires_in=300`. The app is the process that ran
/// OIDC discovery and therefore knows the token endpoint, the client id, its secret
/// and the scope; the extension is a *separate* process that never ran discovery. So
/// without a record of those parameters the extension can only use an access token
/// until it expires, five minutes later, after which the domain stops working. This
/// record is that handover: written by the app at sign-in, read by the extension when
/// it builds its `SessionManager`.
///
/// The tokens themselves are **not** here — they stay in the shared Keychain, which
/// is also where the refreshed pair is written back. This holds only the parameters
/// of the refresh request, which is why plain `UserDefaults` is an appropriate home.
public struct OIDCSessionRecord: Sendable, Equatable, Codable {
    /// The IDP's token endpoint, as discovered at sign-in.
    public let tokenEndpoint: URL
    public let clientID: String
    /// `nil` for a public client. Present for oCIS's registered native clients,
    /// whose secrets are published defaults rather than confidential credentials
    /// (see ``OCISClientRegistration``).
    public let clientSecret: String?
    /// The scope to re-request, or `nil` to let the IDP reuse the granted scope.
    public let scope: String?

    public init(tokenEndpoint: URL, clientID: String, clientSecret: String?, scope: String?) {
        self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scope = scope
    }
}

/// Per-account storage for ``OIDCSessionRecord``, over the same app-group
/// ``KeyValueStore`` seam as ``AccountRegistry`` and ``SpaceCatalogCache``.
///
/// One JSON blob per account under a per-account key. A miss reads as `nil`, and so
/// does a corrupt blob — for a Classic account there is legitimately no record, so
/// "absent" must mean "no refresh available, keep the Basic-auth path" rather than an
/// error that takes the extension down.
public final class OIDCSessionStore {
    private let store: KeyValueStore

    public init(store: KeyValueStore) {
        self.store = store
    }

    public func record(forAccount accountIdentifier: String) -> OIDCSessionRecord? {
        guard let data = store.data(forKey: Self.key(for: accountIdentifier)) else { return nil }
        return try? JSONDecoder().decode(OIDCSessionRecord.self, from: data)
    }

    public func store(_ record: OIDCSessionRecord, forAccount accountIdentifier: String) {
        store.setData(try? JSONEncoder().encode(record), forKey: Self.key(for: accountIdentifier))
    }

    /// Drop the record on sign-out. Leaving it behind would let a later account with
    /// the same identifier inherit stale refresh parameters.
    public func remove(forAccount accountIdentifier: String) {
        store.setData(nil, forKey: Self.key(for: accountIdentifier))
    }

    private static func key(for accountIdentifier: String) -> String {
        "com.owncloud.macos.fileprovider.oidc-session.\(accountIdentifier)"
    }
}
