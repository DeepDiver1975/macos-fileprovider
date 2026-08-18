#if canImport(FileProvider)
import Foundation
import FileProvider
import OwnCloudCore

public extension NSFileProviderDomain {
    /// Build a replicated domain from a ``SyncRoot`` (progress.md Task 7.1). The
    /// sync root owns the *stable* domain identifier — one per oCIS space, the same
    /// value across launches, so the system reuses the existing domain instead of
    /// duplicating it. The display name is resolved separately by
    /// ``DomainDisplayNamer`` because it depends on the whole set of domains (name
    /// collisions), so it is passed in rather than derived from a single account.
    convenience init(syncRoot: SyncRoot, displayName: String) {
        self.init(
            identifier: NSFileProviderDomainIdentifier(syncRoot.domainIdentifier),
            displayName: displayName
        )
    }
}

public extension DomainRemovalChoice {
    /// The framework removal mode for this choice (progress.md Task 5.1). Governs
    /// what happens to already-downloaded files when the domain is removed, so it
    /// must reflect the user's sign-out choice exactly.
    var removalMode: NSFileProviderManager.DomainRemovalMode {
        switch self {
        case .preserveDownloadedUserData: return .preserveDownloadedUserData
        case .removeAll: return .removeAll
        }
    }
}
#endif
