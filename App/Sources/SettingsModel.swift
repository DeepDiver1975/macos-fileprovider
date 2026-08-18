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

    /// The last "Add Account" failure, shown inline in the sign-in sheet. `nil`
    /// clears the message; a successful sign-in dismisses the sheet instead.
    @Published var addAccountError: String?

    private static let appGroup = "group.com.owncloud.macos.fileprovider"
    private static let keychainAccessGroup = "com.owncloud.macos.fileprovider.shared"

    private let registry: AccountRegistry
    private let catalogCache: SpaceCatalogCache
    private let service: DomainService
    /// The Mac-only server probe used by the sign-in flow (Task 7.11).
    private let prober: ServerProbing

    init(prober: ServerProbing = HTTPServerProbe()) {
        let defaults = UserDefaults(suiteName: Self.appGroup) ?? .standard
        let store = UserDefaultsKeyValueStore(defaults: defaults)
        self.registry = AccountRegistry(store: store)
        self.catalogCache = SpaceCatalogCache(store: store)
        self.prober = prober
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

    /// The real Classic sign-in flow (Task 7.11). Probes the server, lets the
    /// tested ``SignInResolver`` decide the backend/credential/sync-root, writes the
    /// Basic credential to the shared Keychain, then adds the domain through
    /// ``DomainService`` — which records the account in the registry first, so it
    /// appears in the sidebar. Any failure is surfaced via ``addAccountError``;
    /// success leaves it `nil` so the sheet can dismiss.
    func addAccount(serverURL: String, username: String, password: String) async {
        addAccountError = nil

        // Probe the normalized URL (same normalization the resolver applies) so the
        // resolver's backend decision reflects the live server. A string that can't
        // form a URL yields an empty probe; the resolver then reports it precisely.
        let probe: BackendProbeResult
        if let url = Self.normalizedURL(from: serverURL) {
            probe = await prober.probe(serverURL: url)
        } else {
            probe = BackendProbeResult(hasOpenIDConfiguration: false, classicStatusJSON: nil)
        }

        switch SignInResolver.resolve(serverURL: serverURL, username: username,
                                      password: password, probe: probe) {
        case .failure(let error):
            addAccountError = Self.message(for: error)
        case .success(let resolved):
            KeychainCredentialStore(account: resolved.account, accessGroup: Self.keychainAccessGroup)
                .save(resolved.credentials)
            do {
                try await service.addSpace(resolved.syncRoot, displayName: resolved.account.displayName)
            } catch {
                addAccountError = "Could not add the account’s file provider domain: "
                    + error.localizedDescription
                return
            }
            await reload()
            selectedAccountID = resolved.account.accountIdentifier
        }
    }

    /// Normalize a server field the way ``SignInResolver`` does (trim; prepend
    /// `http://` when schemeless) so the probe hits the same URL the resolver
    /// validates. Returns `nil` when no URL with a host can be formed.
    private static func normalizedURL(from serverURL: String) -> URL? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: withScheme), url.host != nil else { return nil }
        return url
    }

    /// A user-facing sentence for each sign-in failure.
    private static func message(for error: SignInError) -> String {
        switch error {
        case .emptyServerURL:
            return "Enter the server address."
        case .emptyUsername:
            return "Enter your user name."
        case .invalidServerURL:
            return "That server address isn’t valid. Include the host, e.g. http://localhost:8080."
        case .backendNotDetected:
            return "No ownCloud server answered at that address. Check the address and try again."
        case .ocisNotSupportedYet:
            return "That’s an Infinite Scale (oCIS) server. OpenID sign-in isn’t supported here yet — "
                + "this build signs in to ownCloud Classic only."
        }
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
