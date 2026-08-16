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

/// The account an `NSFileProviderDomain` is built from. Backend-agnostic; the
/// Mac-only layer maps `domainIdentifier`/`displayName` onto
/// `NSFileProviderDomain(identifier:displayName:)`.
public struct AccountDescriptor: Sendable, Equatable {
    public let backend: Backend
    public let serverURL: URL
    public let username: String

    public init(backend: Backend, serverURL: URL, username: String) {
        self.backend = backend
        self.serverURL = serverURL
        self.username = username
    }

    /// Stable identifier for the domain — same account, same id across launches,
    /// so the system reuses the existing domain rather than duplicating it.
    public var domainIdentifier: String {
        "\(backend.rawValue)|\(serverURL.absoluteString)|\(username)"
    }

    /// User-facing domain name, e.g. `einstein@ocis.test`.
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
