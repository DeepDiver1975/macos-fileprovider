import Foundation

/// Which backend an account talks to.
public enum Backend: String, Sendable, Equatable {
    case classic
    case ocis
}

/// The signals gathered by probing a server URL during sign-in. The actual HTTP
/// probes (fetching `/.well-known/openid-configuration` and `/status.php`) are
/// performed by the Mac-only networking layer; the *decision* is made here so it
/// is testable.
public struct BackendProbeResult: Sendable, Equatable {
    /// A parseable `/.well-known/openid-configuration` was served — the oCIS / OIDC signal.
    public let hasOpenIDConfiguration: Bool
    /// The body of `/status.php`, if any (ownCloud Classic signal).
    public let classicStatusJSON: Data?

    public init(hasOpenIDConfiguration: Bool, classicStatusJSON: Data?) {
        self.hasOpenIDConfiguration = hasOpenIDConfiguration
        self.classicStatusJSON = classicStatusJSON
    }
}

/// Decides the backend from a probe result.
public enum BackendDetector {
    /// oCIS wins when OIDC is present (a modern oCIS also serves a `status.php`
    /// shim). Classic is chosen only when `status.php` parses as an installed
    /// ownCloud. `nil` when neither signal is trustworthy.
    public static func detect(from probe: BackendProbeResult) -> Backend? {
        if probe.hasOpenIDConfiguration {
            return .ocis
        }
        if let data = probe.classicStatusJSON, isValidClassicStatus(data) {
            return .classic
        }
        return nil
    }

    private static func isValidClassicStatus(_ data: Data) -> Bool {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        // A genuine status.php reports installed == true.
        return (object["installed"] as? Bool) == true
    }
}

/// An ownCloud account — the *credential* identity. Backend-agnostic.
///
/// One account can back several `NSFileProviderDomain`s (one per oCIS space), so
/// the account identity (``accountIdentifier``, which keys the Keychain item) is
/// deliberately distinct from the *domain* identity (``SyncRoot/domainIdentifier``,
/// Task 7.1): N spaces of one account share one credential item.
public struct AccountDescriptor: Sendable, Equatable {
    public let backend: Backend
    public let serverURL: URL
    public let username: String

    public init(backend: Backend, serverURL: URL, username: String) {
        self.backend = backend
        self.serverURL = serverURL
        self.username = username
    }

    /// Reconstruct the account from an ``accountIdentifier`` — the inverse of the
    /// computed property below.
    ///
    /// The three `|`-separated segments are backend, percent-encoded serverURL, and
    /// percent-encoded username (see ``accountIdentifier`` for why they are encoded).
    /// Returns `nil` if there are not exactly three segments, the backend token is
    /// unknown, or the server URL does not parse.
    public init?(accountIdentifier: String) {
        let parts = accountIdentifier.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let backend = Backend(rawValue: String(parts[0])),
              let serverString = String(parts[1]).removingPercentEncoding,
              let serverURL = URL(string: serverString),
              let username = String(parts[2]).removingPercentEncoding
        else { return nil }
        self.init(backend: backend, serverURL: serverURL, username: username)
    }

    /// Stable identifier for the *credentials* — same account, same id across
    /// launches, so the Keychain item is reused rather than duplicated. It is also
    /// the verbatim tail of ``SyncRoot/domainIdentifier``.
    ///
    /// `NSFileProviderDomain` forbids `/` and `:` in the identifier
    /// (`NSFileProviderDomain.h`), so a raw server URL (which always contains both)
    /// is rejected with `EINVAL`. The serverURL and username segments are therefore
    /// percent-encoded — the encoding also escapes `|`, so each of the three
    /// segments is unambiguous.
    public var accountIdentifier: String {
        "\(backend.rawValue)|\(AccountDescriptor.encodeSegment(serverURL.absoluteString))|\(AccountDescriptor.encodeSegment(username))"
    }

    /// Percent-encode a segment so it carries none of the identifier's structural
    /// or forbidden characters (`|`, `/`, `:`). The allowed set is the URL
    /// unreserved set, which excludes all three.
    static func encodeSegment(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// User-facing account name, e.g. `einstein@ocis.test`.
    public var displayName: String {
        let host = serverURL.host ?? serverURL.absoluteString
        return "\(username)@\(host)"
    }
}

/// Mirrors `NSFileProviderManager.DomainRemovalMode`: what happens to
/// already-downloaded files when a domain is removed.
public enum DomainRemovalChoice: Sendable, Equatable {
    /// Keep materialised files on disk (as local, non-synced copies).
    case preserveDownloadedUserData
    /// Remove everything the provider put on disk.
    case removeAll

    /// Default for the "sign out" action: don't destroy the user's local copies.
    public static let `default`: DomainRemovalChoice = .preserveDownloadedUserData
}
