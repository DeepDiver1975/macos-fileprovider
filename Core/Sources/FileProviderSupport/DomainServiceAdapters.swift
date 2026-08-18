#if canImport(FileProvider)
import Foundation
import FileProvider
import OwnCloudCore

/// The Mac-only adapter wiring `NSFileProviderManager` into the headless
/// ``DomainManaging`` seam the ``DomainService`` drives (Task 7.5). It is
/// deliberately thin — all ordering and policy live in the service — so the only
/// logic here is mapping domains ↔ sync roots and bridging the completion-handler
/// APIs into `async`.
public struct SystemDomainManager: DomainManaging {

    public init() {}

    public func existingSyncRoots() async throws -> [SyncRoot] {
        let domains: [NSFileProviderDomain] = try await withCheckedThrowingContinuation { continuation in
            NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: domains) }
            }
        }
        // A domain whose identifier no longer parses as a sync root is skipped
        // rather than crashing enumeration — the same tolerant posture the
        // credential and registry blobs take.
        return domains.compactMap { SyncRoot(domainIdentifier: $0.identifier.rawValue) }
    }

    public func add(_ syncRoot: SyncRoot, displayName: String) async throws {
        let domain = NSFileProviderDomain(syncRoot: syncRoot, displayName: displayName)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSFileProviderManager.add(domain) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    public func remove(_ syncRoot: SyncRoot, mode: DomainRemovalChoice) async throws {
        let domain = NSFileProviderDomain(syncRoot: syncRoot, displayName: syncRoot.account.displayName)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSFileProviderManager.remove(domain, mode: mode.removalMode) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}

/// Deletes an account's Keychain credential through ``KeychainCredentialStore``
/// (Task 7.5). The store is keyed by the account's stable identifier, so all N
/// per-space domains of one account share the single item this clears.
public struct KeychainCredentialDeleter: CredentialDeleting {
    private let accessGroup: String?

    public init(accessGroup: String?) {
        self.accessGroup = accessGroup
    }

    public func deleteCredentials(forAccount accountIdentifier: String) async throws {
        // The store addresses the item by the descriptor's accountIdentifier;
        // reconstruct a descriptor purely to key the delete. A malformed identifier
        // (should never occur for a record we wrote) is a no-op.
        guard let account = AccountDescriptor(accountIdentifier: accountIdentifier) else { return }
        KeychainCredentialStore(account: account, accessGroup: accessGroup).clear()
    }
}

/// The single-instance guard (Task 7.5), a thin wrapper over ``FileLock``. It takes
/// the lock once and holds it for the process lifetime — releasing only when the
/// app quits closes the descriptor — so a second app copy fails to reconcile. The
/// mutable held-flag is guarded by a lock, hence `@unchecked Sendable`.
public final class FileLockInstanceLock: InstanceLock, @unchecked Sendable {
    private let lock: FileLock
    private let mutex = NSLock()
    private var held = false

    public init(path: String) {
        self.lock = FileLock(path: path)
    }

    public func ensureSingleInstance() throws {
        mutex.lock()
        defer { mutex.unlock() }
        if held { return }
        held = try lock.tryLockExclusive()
        if !held { throw SingleInstanceError.anotherInstanceRunning }
    }
}
#endif
