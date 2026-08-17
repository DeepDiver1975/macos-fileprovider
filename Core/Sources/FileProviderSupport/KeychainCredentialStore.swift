#if canImport(Security)
import Foundation
import Security
import OwnCloudCore

/// The raw key-value keychain operations `KeychainCredentialStore` needs, behind
/// a protocol so the store's logic is testable without a signed, entitled host.
/// The production implementation is ``SecItemKeychainBackend`` (real `SecItem`
/// calls); tests supply an in-memory fake.
public protocol KeychainBackend: AnyObject {
    func loadData(service: String, account: String, accessGroup: String?) -> Data?
    func saveData(_ data: Data, service: String, account: String, accessGroup: String?)
    func deleteData(service: String, account: String, accessGroup: String?)
}

/// The concrete ``CredentialStore`` shared by the containing app's sign-in flow
/// and the File Provider extension via the Keychain access group (progress.md
/// Task 1.3 / 2.5). One generic-password item per account, addressed by the
/// account's stable ``AccountDescriptor/domainIdentifier`` so both processes
/// resolve the same credentials, with the payload serialized by
/// ``CredentialCoder``.
///
/// The `SecItem` calls need the shared-keychain entitlement and a signed host, so
/// they live behind the injectable ``KeychainBackend``; everything else is
/// exercised headlessly.
public final class KeychainCredentialStore: CredentialStore {

    /// The keychain service all of this provider's credential items share.
    public static let service = "com.owncloud.macos.fileprovider.credentials"

    private let account: String
    private let accessGroup: String?
    private let backend: KeychainBackend

    /// - Parameters:
    ///   - account: the account whose credentials this store holds; its stable
    ///     identifier is the keychain item's account key.
    ///   - accessGroup: the shared Keychain access group
    ///     (`$(AppIdentifierPrefix)com.owncloud.macos.fileprovider.shared`), or
    ///     `nil` to use the default (app-local) keychain.
    ///   - backend: the keychain operations; defaults to real `SecItem`.
    public init(
        account: AccountDescriptor,
        accessGroup: String?,
        backend: KeychainBackend = SecItemKeychainBackend()
    ) {
        self.account = account.domainIdentifier
        self.accessGroup = accessGroup
        self.backend = backend
    }

    public func load() -> Credentials? {
        guard let data = backend.loadData(service: Self.service, account: account, accessGroup: accessGroup) else {
            return nil
        }
        // A blob that no longer decodes (format drift, corruption) is treated as
        // "no credentials" rather than crashing the extension.
        return try? CredentialCoder.decode(data)
    }

    public func save(_ credentials: Credentials) {
        guard let data = try? CredentialCoder.encode(credentials) else { return }
        backend.saveData(data, service: Self.service, account: account, accessGroup: accessGroup)
    }

    public func clear() {
        backend.deleteData(service: Self.service, account: account, accessGroup: accessGroup)
    }
}

/// `SecItem`-backed ``KeychainBackend``. Stores a single generic-password item
/// per (service, account, accessGroup); `save` upserts. Requires the shared
/// keychain-access-group entitlement and a signed host to succeed — hence it is
/// never exercised in the headless test suite.
public final class SecItemKeychainBackend: KeychainBackend {

    public init() {}

    private func baseQuery(service: String, account: String, accessGroup: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    public func loadData(service: String, account: String, accessGroup: String?) -> Data? {
        var query = baseQuery(service: service, account: account, accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    public func saveData(_ data: Data, service: String, account: String, accessGroup: String?) {
        let query = baseQuery(service: service, account: account, accessGroup: accessGroup)
        let attributes: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    public func deleteData(service: String, account: String, accessGroup: String?) {
        let query = baseQuery(service: service, account: account, accessGroup: accessGroup)
        SecItemDelete(query as CFDictionary)
    }
}
#endif
