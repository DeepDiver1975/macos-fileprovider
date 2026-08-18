import SwiftUI
import FileProvider
import OwnCloudCore
import FileProviderSupport

/// View model for the settings window (progress.md Task 7.8).
///
/// It is intentionally thin: it holds no policy of its own. The registry, the
/// display-only catalog cache, and the `DomainService` ordering all live in
/// `OwnCloudCore`/`FileProviderSupport`; the *decisions* the UI renders come from
/// the tested presenters (`SpacesTab`, `SpaceRemovalPrompt`, `DomainEnablementStatus`).
/// This class only turns those into `@Published` state and forwards user actions.
@MainActor
final class SettingsModel: ObservableObject {

    @Published var accounts: [AccountDescriptor] = []
    @Published var selectedAccountID: String?

    /// Sync roots the system currently has domains for — the source of truth for
    /// which spaces are selected (Task 7.4: no parallel selection list).
    @Published private var existingRoots: [SyncRoot] = []
    /// System Settings toggle state per account (`NSFileProviderDomain.userEnabled`).
    @Published private var userEnabledByAccount: [String: Bool] = [:]

    /// The in-flight deselect confirmation, if any. Drives the Spaces-tab dialog.
    @Published var pendingRemoval: SpaceRemovalPrompt?
    private var pendingRemovalRoot: SyncRoot?

    private static let appGroup = "group.com.owncloud.macos.fileprovider"
    private static let keychainAccessGroup = "com.owncloud.macos.fileprovider.shared"

    private let registry: AccountRegistry
    private let catalogCache: SpaceCatalogCache
    private let service: DomainService

    init() {
        let defaults = UserDefaults(suiteName: Self.appGroup) ?? .standard
        let store = UserDefaultsKeyValueStore(defaults: defaults)
        self.registry = AccountRegistry(store: store)
        self.catalogCache = SpaceCatalogCache(store: store)
        self.service = DomainService(
            registry: registry,
            domainManager: SystemDomainManager(),
            credentialDeleter: KeychainCredentialDeleter(accessGroup: Self.keychainAccessGroup),
            instanceLock: FileLockInstanceLock(
                path: (Self.appGroupContainerPath as NSString).appendingPathComponent("settings.lock"))
        )
    }

    // MARK: - Loading

    var selectedAccount: AccountDescriptor? {
        accounts.first { $0.accountIdentifier == selectedAccountID }
    }

    func reload() async {
        accounts = registry.accounts.map(\.descriptor)
        if selectedAccountID == nil { selectedAccountID = accounts.first?.accountIdentifier }
        existingRoots = (try? await service.existingSyncRoots()) ?? []
        await refreshEnablement()
    }

    private func refreshEnablement() async {
        var result: [String: Bool] = [:]
        let domains: [NSFileProviderDomain] = (try? await NSFileProviderManager.domains()) ?? []
        for domain in domains {
            guard let root = SyncRoot(domainIdentifier: domain.identifier.rawValue) else { continue }
            let id = root.account.accountIdentifier
            // An account is blocked if *any* of its domains is user-disabled.
            result[id] = (result[id] ?? true) && domain.userEnabled
        }
        userEnabledByAccount = result
    }

    // MARK: - Presenters (all decisions come from the tested core types)

    func spacesTab(for account: AccountDescriptor) -> SpacesTab {
        let catalog = account.backend == .classic
            ? .classic
            : (catalogCache.catalog(forAccount: account.accountIdentifier) ?? SpaceCatalog(spaces: []))
        let mine = existingRoots.filter { $0.account.accountIdentifier == account.accountIdentifier }
        return SpacesTab.make(account: account, catalog: catalog, existing: mine)
    }

    func enablementStatus(for account: AccountDescriptor) -> DomainEnablementStatus? {
        guard let enabled = userEnabledByAccount[account.accountIdentifier] else { return nil }
        return DomainEnablementStatus.make(userEnabled: enabled)
    }

    // MARK: - Space selection

    /// A toggle binding for one space row. Turning it on adds the domain; turning
    /// it off raises the concretely-worded deselect prompt rather than removing
    /// immediately.
    func selectionBinding(account: AccountDescriptor, row: SpaceRow) -> Binding<Bool> {
        Binding(
            get: { row.isSelected },
            set: { newValue in
                guard let syncRoot = SyncRoot(account: account, driveID: row.driveID) else { return }
                if newValue {
                    Task { await self.addSpace(syncRoot, displayName: row.name) }
                } else {
                    self.presentRemovalPrompt(for: syncRoot, spaceName: row.name)
                }
            }
        )
    }

    private func addSpace(_ syncRoot: SyncRoot, displayName: String) async {
        try? await service.addSpace(syncRoot, displayName: displayName)
        await reload()
    }

    private func presentRemovalPrompt(for syncRoot: SyncRoot, spaceName: String) {
        pendingRemovalRoot = syncRoot
        pendingRemoval = SpaceRemovalPrompt.make(
            spaceName: spaceName,
            downloadedBytes: downloadedBytes(for: syncRoot))
    }

    var isRemovalPromptPresented: Binding<Bool> {
        Binding(
            get: { self.pendingRemoval != nil },
            set: { if !$0 { self.pendingRemoval = nil } }
        )
    }

    func resolveRemoval(_ choice: DomainRemovalChoice) {
        guard let syncRoot = pendingRemovalRoot else { return }
        pendingRemoval = nil
        pendingRemovalRoot = nil
        Task {
            try? await service.removeSpace(syncRoot, mode: choice)
            await reload()
        }
    }

    func cancelRemoval() {
        pendingRemoval = nil
        pendingRemovalRoot = nil
    }

    /// Bytes this space has materialised on disk, for the deselect prompt. Best
    /// effort: the user-visible directory size, or 0 if it cannot be measured.
    private func downloadedBytes(for syncRoot: SyncRoot) -> Int {
        // Measuring materialised size requires the domain's on-disk URL, which is
        // fetched asynchronously; the prompt is shown synchronously, so a 0 here
        // simply drops the size clause ("Keep the downloaded files"). A follow-up
        // can pre-measure sizes during reload and cache them per root.
        0
    }

    // MARK: - Account actions

    func confirmSignOut(_ account: AccountDescriptor) {
        Task {
            try? await service.signOut(account, mode: .preserveDownloadedUserData)
            await reload()
        }
    }

    func beginAddAccount() {
        // Sign-in (Classic username/password, oCIS OIDC via ASWebAuthenticationSession)
        // is presented from here; the flow itself is the remaining Mac-only UI work.
    }

    func collectDiagnostics(_ account: AccountDescriptor) {
        Task {
            let roots = existingRoots.filter { $0.account.accountIdentifier == account.accountIdentifier }
            for root in roots {
                let domain = NSFileProviderDomain(syncRoot: root, displayName: account.displayName)
                guard let manager = NSFileProviderManager(for: domain) else { continue }
                // Collect diagnostics for the whole domain (its root container).
                // The reason is user-initiated, not an error, so pass a neutral one.
                // The API is macOS 15.4+; on older systems this is a no-op.
                guard #available(macOS 15.4, *) else { continue }
                let reason = NSError(domain: "com.owncloud.macos.fileprovider", code: 0,
                                     userInfo: [NSLocalizedDescriptionKey: "User-requested diagnostics"])
                try? await manager.requestDiagnosticCollection(for: .rootContainer, errorReason: reason)
            }
        }
    }

    func resetDomains(_ account: AccountDescriptor) {
        Task {
            let roots = existingRoots.filter { $0.account.accountIdentifier == account.accountIdentifier }
            for root in roots {
                try? await service.removeSpace(root, mode: .removeAll)
                try? await service.addSpace(root, displayName: account.displayName)
            }
            await reload()
        }
    }

    /// Called when the app is opened via the `owncloud-fileprovider://reconnect`
    /// deep link from the UI extension (Task 7.9): select that account and present
    /// its sign-in.
    func handleLaunch(_ url: URL) {
        guard case let .reconnect(accountIdentifier) = AppLaunchURL.parse(url) else { return }
        selectedAccountID = accountIdentifier
        // Presenting the sign-in sheet is the same path beginAddAccount drives.
    }

    private static var appGroupContainerPath: String {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .path ?? NSTemporaryDirectory()
    }
}
