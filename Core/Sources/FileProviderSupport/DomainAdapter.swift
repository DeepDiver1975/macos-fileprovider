#if canImport(FileProvider)
import Foundation
import FileProvider
import OwnCloudCore

public extension NSFileProviderDomain {
    /// Build a replicated domain from a backend-agnostic ``AccountDescriptor``
    /// (progress.md Task 5.1). The descriptor owns the *stable* identifier — the
    /// same account yields the same id across launches, so the system reuses the
    /// existing domain instead of duplicating it — and the user-facing name.
    convenience init(account: AccountDescriptor) {
        self.init(
            identifier: NSFileProviderDomainIdentifier(account.domainIdentifier),
            displayName: account.displayName
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
