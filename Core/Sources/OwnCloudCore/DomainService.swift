import Foundation

/// The platform domain-list operations the service drives (Task 7.5). The Mac-only
/// adapter over `NSFileProviderManager` lives in `FileProviderSupport`; this seam
/// keeps the service's *ordering* logic testable headlessly.
public protocol DomainManaging: Sendable {
    /// The sync roots the system currently has domains for
    /// (`getDomainsWithCompletionHandler`, mapped back through `SyncRoot`).
    func existingSyncRoots() async throws -> [SyncRoot]
    func add(_ syncRoot: SyncRoot, displayName: String) async throws
    func remove(_ syncRoot: SyncRoot, mode: DomainRemovalChoice) async throws
}

/// Per-account credential deletion (the Keychain item). Its own seam so sign-out
/// ordering — domains, *then* credentials, *then* record — is testable.
public protocol CredentialDeleting: Sendable {
    func deleteCredentials(forAccount accountIdentifier: String) async throws
}

/// Enforces that only one app instance reconciles at a time. Nextcloud ships
/// `singleinstancemanager_mac` for the same reason: two copies reconciling
/// concurrently race on the domain list. The Mac adapter is a thin file-lock.
public protocol InstanceLock: Sendable {
    func ensureSingleInstance() throws
}

/// Thrown when another instance already holds the single-instance lock.
public enum SingleInstanceError: Error, Equatable {
    case anotherInstanceRunning
}

/// The headless orchestrator behind the settings window (Task 7.5).
///
/// It owns the **ordering** that makes any crash leave recoverable state — the
/// registry brackets the domain lifetime:
///   - **add**: write the account record *before* adding the domain, so a
///     zero-space account is representable and a crash mid-add leaves at worst a
///     record with no domain (harmless — it just means "known, no spaces");
///   - **sign-out**: remove domains → delete credentials → delete the record
///     *last*, so a crash leaves at worst an orphan domain (detectable) or a
///     missing credential (reads as "signed out"), never a record pointing at a
///     domain whose credential is gone.
///
/// Orphans — domains whose account the registry never knew — are surfaced by
/// `reconcile` but **never removed silently**; removal is a confirmed user action
/// via `removeOrphans`.
public final class DomainService {
    private let registry: AccountRegistering
    private let domainManager: DomainManaging
    private let credentialDeleter: CredentialDeleting
    private let instanceLock: InstanceLock

    public init(registry: AccountRegistering,
                domainManager: DomainManaging,
                credentialDeleter: CredentialDeleting,
                instanceLock: InstanceLock) {
        self.registry = registry
        self.domainManager = domainManager
        self.credentialDeleter = credentialDeleter
        self.instanceLock = instanceLock
    }

    /// The sync roots the system currently has domains for.
    public func existingSyncRoots() async throws -> [SyncRoot] {
        try await domainManager.existingSyncRoots()
    }

    /// Add a single space: record first, then domain.
    public func addSpace(_ syncRoot: SyncRoot, displayName: String) async throws {
        registry.upsert(record(for: syncRoot.account))
        try await domainManager.add(syncRoot, displayName: displayName)
    }

    /// Deselect one space: remove only that domain. The account record and its
    /// credential stay — the account may still have other spaces, or legitimately
    /// zero (the registry's whole reason to exist).
    public func removeSpace(_ syncRoot: SyncRoot, mode: DomainRemovalChoice) async throws {
        try await domainManager.remove(syncRoot, mode: mode)
    }

    /// Sign an account out entirely: remove every one of its domains, then delete
    /// its credential, then delete its record last.
    public func signOut(_ account: AccountDescriptor, mode: DomainRemovalChoice) async throws {
        let mine = try await domainManager.existingSyncRoots()
            .filter { $0.account.accountIdentifier == account.accountIdentifier }
        for syncRoot in mine {
            try await domainManager.remove(syncRoot, mode: mode)
        }
        try await credentialDeleter.deleteCredentials(forAccount: account.accountIdentifier)
        registry.remove(accountIdentifier: account.accountIdentifier)
    }

    /// Apply the user's current selection against the system domain list, returning
    /// the plan actually applied. Adds and removes are performed; **orphans are
    /// returned but never removed** (removal is a confirmed action — `removeOrphans`).
    ///
    /// `displayNames` maps each intent root's `domainIdentifier` to its resolved
    /// name (from `DomainDisplayNamer`); a missing entry falls back to the account's.
    @discardableResult
    public func reconcile(intent: [SyncRoot],
                          displayNames: [String: String]) async throws -> DomainPlan {
        try instanceLock.ensureSingleInstance()

        let existing = try await domainManager.existingSyncRoots()
        let plan = DomainReconciler.plan(registry: registry.accounts,
                                         existing: existing,
                                         intent: intent)
        for syncRoot in plan.add {
            let name = displayNames[syncRoot.domainIdentifier] ?? syncRoot.account.displayName
            try await addSpace(syncRoot, displayName: name)
        }
        for syncRoot in plan.remove {
            try await domainManager.remove(syncRoot, mode: .preserveDownloadedUserData)
        }
        return plan
    }

    /// Remove orphan domains the user confirmed. Domains only — an orphan has no
    /// registry record by definition, and its credential (if any) is left for a
    /// deliberate sign-out.
    public func removeOrphans(_ orphans: [SyncRoot], mode: DomainRemovalChoice) async throws {
        for syncRoot in orphans {
            try await domainManager.remove(syncRoot, mode: mode)
        }
    }

    // MARK: - Helpers

    private func record(for account: AccountDescriptor) -> AccountRecord {
        AccountRecord(accountIdentifier: account.accountIdentifier, backend: account.backend,
                      serverURL: account.serverURL, username: account.username)
    }
}
