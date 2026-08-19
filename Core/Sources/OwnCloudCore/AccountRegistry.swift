import Foundation

/// The minimal key-value seam the registry and space-catalog cache persist over
/// (Task 7.3). In production this is backed by the app group `UserDefaults`
/// (``AppGroup/identifier``); tests inject a fake. Kept to raw `Data` so the same
/// seam serves both JSON payloads.
public protocol KeyValueStore: AnyObject {
    func data(forKey key: String) -> Data?
    func setData(_ data: Data?, forKey key: String)
}

/// The production ``KeyValueStore``, backed by `UserDefaults`. Construct it with
/// the app group suite (`UserDefaults(suiteName: AppGroup.identifier)`) so the app
/// and the extension share one registry — the identifier must be the team-prefixed
/// one, or the extension silently sees an empty suite (see ``AppGroup``).
public final class UserDefaultsKeyValueStore: KeyValueStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func data(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    public func setData(_ data: Data?, forKey key: String) {
        if let data {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

/// One row of the account registry: *which accounts exist*, independent of how
/// many spaces (domains) each currently has. Credentials never live here — they
/// stay in the Keychain, keyed by `accountIdentifier` (see [[KeychainCredentialStore]]).
public struct AccountRecord: Sendable, Equatable, Hashable, Codable {
    public let accountIdentifier: String
    public let backend: Backend
    public let serverURL: URL
    public let username: String

    public init(accountIdentifier: String, backend: Backend, serverURL: URL, username: String) {
        self.accountIdentifier = accountIdentifier
        self.backend = backend
        self.serverURL = serverURL
        self.username = username
    }

    /// The descriptor this record represents. `accountIdentifier` is derivable
    /// from the descriptor, so it is not re-stored on `AccountDescriptor`.
    public var descriptor: AccountDescriptor {
        AccountDescriptor(backend: backend, serverURL: serverURL, username: username)
    }
}

/// The mutation seam the domain service (Task 7.5) drives the registry through, so
/// its ordering logic is testable against a fake. `AccountRegistry` is the
/// production conformer.
public protocol AccountRegistering: AnyObject {
    var accounts: [AccountRecord] { get }
    func upsert(_ record: AccountRecord)
    func remove(accountIdentifier: String)
}

/// The registry of known accounts (Task 7.3).
///
/// The system domain list is the source of truth for *what syncs*; this registry
/// exists for exactly one thing the domain list cannot express — an account with
/// **zero** spaces selected has no domains and would otherwise vanish. It is one
/// JSON blob under one key, so a whole-list read/write is cheap and atomic enough.
///
/// A blob that no longer decodes is treated as "no accounts" rather than a crash —
/// the same tolerant posture `KeychainCredentialStore` takes for a corrupt item.
public final class AccountRegistry: AccountRegistering {
    public static let storageKey = "com.owncloud.macos.fileprovider.accounts"

    private let store: KeyValueStore
    private var records: [AccountRecord]

    public init(store: KeyValueStore) {
        self.store = store
        self.records = Self.decode(store.data(forKey: Self.storageKey))
    }

    /// The known accounts, in insertion order.
    public var accounts: [AccountRecord] { records }

    /// Insert `record`, or replace the existing one with the same identifier
    /// (preserving its position). Persists immediately.
    public func upsert(_ record: AccountRecord) {
        if let index = records.firstIndex(where: { $0.accountIdentifier == record.accountIdentifier }) {
            records[index] = record
        } else {
            records.append(record)
        }
        persist()
    }

    /// Drop the account with `accountIdentifier`, if present. Persists immediately.
    public func remove(accountIdentifier: String) {
        records.removeAll { $0.accountIdentifier == accountIdentifier }
        persist()
    }

    private func persist() {
        store.setData(try? JSONEncoder().encode(records), forKey: Self.storageKey)
    }

    private static func decode(_ data: Data?) -> [AccountRecord] {
        guard let data, let records = try? JSONDecoder().decode([AccountRecord].self, from: data) else {
            return []
        }
        return records
    }
}

/// A display-only cache of each account's last-seen space catalog (Task 7.3).
///
/// This is never authoritative — the live `me/drives` listing always wins. It
/// exists so the settings window can render an account's spaces instantly (and
/// while offline) before the refresh completes. One JSON blob per account under a
/// per-account key; a miss or a corrupt blob simply reads as `nil`.
public final class SpaceCatalogCache {
    private let store: KeyValueStore

    public init(store: KeyValueStore) {
        self.store = store
    }

    public func catalog(forAccount accountIdentifier: String) -> SpaceCatalog? {
        guard let data = store.data(forKey: Self.key(for: accountIdentifier)) else { return nil }
        return try? JSONDecoder().decode(SpaceCatalog.self, from: data)
    }

    public func store(_ catalog: SpaceCatalog, forAccount accountIdentifier: String) {
        store.setData(try? JSONEncoder().encode(catalog), forKey: Self.key(for: accountIdentifier))
    }

    private static func key(for accountIdentifier: String) -> String {
        "com.owncloud.macos.fileprovider.spaces.\(accountIdentifier)"
    }
}
