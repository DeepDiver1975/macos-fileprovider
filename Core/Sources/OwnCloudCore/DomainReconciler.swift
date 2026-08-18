import Foundation

/// The three actions reconciling the current selection against the system's
/// domain list produces (Task 7.4). All three lists preserve the order of the
/// input they are drawn from.
public struct DomainPlan: Sendable, Equatable {
    /// Sync roots to add (`NSFileProviderManager.add`).
    public let add: [SyncRoot]
    /// Sync roots of *known* accounts the user deselected (`remove(_:mode:)`).
    public let remove: [SyncRoot]
    /// Sync roots whose account is absent from the registry — a leftover install
    /// or an account removed while the app was closed. Removed **only on
    /// confirmation** (Task 7.5), never silently, hence kept distinct from `remove`.
    public let orphans: [SyncRoot]

    public init(add: [SyncRoot], remove: [SyncRoot], orphans: [SyncRoot]) {
        self.add = add
        self.remove = remove
        self.orphans = orphans
    }
}

/// Diffs the current selection against the system's domain list (Task 7.4).
///
/// A pure function, following the pattern `BackendDetector` and `Paginator`
/// already establish. **The system's domain list is the source of truth** for
/// what syncs; there is no parallel "selected spaces" store to drift out of sync.
public enum DomainReconciler {

    /// Reconcile three inputs into a ``DomainPlan``:
    ///   - `registry`: the known accounts (the zero-space guard).
    ///   - `existing`: the sync roots the system currently has domains for.
    ///   - `intent`: the sync roots the user's current selection asks for.
    ///
    /// A root in `existing` whose account is unknown is an **orphan**, regardless
    /// of `intent`. A root in `existing` of a *known* account that is no longer in
    /// `intent` is a **remove**. A root in `intent` not yet in `existing` is an
    /// **add**.
    public static func plan(registry: [AccountRecord],
                            existing: [SyncRoot],
                            intent: [SyncRoot]) -> DomainPlan {
        let knownAccounts = Set(registry.map(\.accountIdentifier))
        let existingSet = Set(existing)
        let intentSet = Set(intent)

        let add = intent.filter { !existingSet.contains($0) }

        var remove: [SyncRoot] = []
        var orphans: [SyncRoot] = []
        for root in existing {
            if !knownAccounts.contains(root.account.accountIdentifier) {
                orphans.append(root)                       // unknown account → orphan
            } else if !intentSet.contains(root) {
                remove.append(root)                        // known account, deselected
            }
        }
        return DomainPlan(add: add, remove: remove, orphans: orphans)
    }
}
