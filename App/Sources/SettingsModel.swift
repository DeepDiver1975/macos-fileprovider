import SwiftUI
import FileProvider
import OwnCloudCore
import FileProviderSupport
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

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

    /// Which step the Add Account sheet is on (issue #17). Whether credentials are
    /// even wanted depends on what the server turns out to be, so the sheet asks for
    /// the server first and this — a tested core type — says what comes next.
    @Published var addAccountFlow: AddAccountFlow = .server

    /// Set once an account has actually been added, which is the sheet's cue to
    /// dismiss. A step that merely advances (server → Classic credentials) also
    /// clears `addAccountError`, so "no error" alone would dismiss the sheet
    /// mid-flow.
    @Published var addAccountDidFinish = false

    /// The probe from the server step, reused by the Classic credentials step so
    /// submitting the password does not re-probe the same server.
    private var probeForCurrentServer: (server: String, result: BackendProbeResult)?

    /// Team-prefixed, as the entitlement requires — see ``AppGroup``. The bare id
    /// would keep *this* process working while silently denying the extension.
    private static let appGroup = AppGroup.identifier
    private static let keychainAccessGroup = "com.owncloud.macos.fileprovider.shared"

    private let registry: AccountRegistry
    private let catalogCache: SpaceCatalogCache
    /// Refresh parameters handed to the extension so an oCIS mount survives past the
    /// 5-minute access-token lifetime (issue #17).
    private let sessionStore: OIDCSessionStore
    private let service: DomainService
    /// The Mac-only server probe used by the sign-in flow (Task 7.11).
    private let prober: ServerProbing

    init(prober: ServerProbing = HTTPServerProbe()) {
        let defaults = UserDefaults(suiteName: Self.appGroup) ?? .standard
        let store = UserDefaultsKeyValueStore(defaults: defaults)
        self.registry = AccountRegistry(store: store)
        self.catalogCache = SpaceCatalogCache(store: store)
        self.sessionStore = OIDCSessionStore(store: store)
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
            // The service deletes the Keychain item and the registry record; the OIDC
            // refresh parameters are ours to drop, and leaving them would let a later
            // sign-in to the same account inherit stale ones.
            sessionStore.remove(forAccount: account.accountIdentifier)
            await reload()
        }
    }

    /// Reset the Add Account sheet to its first step. Called when the sheet is
    /// opened, so a previous attempt's step and error never leak into a new one.
    func beginAddAccount() {
        addAccountError = nil
        addAccountFlow = .server
        addAccountDidFinish = false
        probeForCurrentServer = nil
    }

    /// Submit the Add Account sheet's current step (Task 7.11, issue #17).
    ///
    /// The sheet has no branching logic of its own: it hands over whatever fields it
    /// has and this method probes the server, lets the tested ``SignInResolver``
    /// decide which sign-in the server calls for, and either advances the flow
    /// (Classic → collect credentials) or runs the OIDC browser flow (oCIS).
    /// `username`/`password` are empty on the server step and unused there.
    func submitAddAccount(serverURL: String, username: String, password: String) async {
        addAccountError = nil

        // Probe the normalized URL (same normalization the resolver applies) so the
        // resolver's backend decision reflects the live server. A string that can't
        // form a URL yields an empty probe; the resolver then reports it precisely.
        let probe = await probeResult(for: serverURL)

        switch SignInResolver.route(serverURL: serverURL, probe: probe) {
        case .failure(let error):
            addAccountError = Self.message(for: error)
        case .success(.oidc(let url)):
            await signInWithOIDC(serverURL: url)
        case .success(.classic(let url)):
            // A Classic server needs a username and password. On the server step
            // those have not been collected yet — advance and wait for them.
            guard addAccountFlow.showsCredentialFields else {
                addAccountFlow = .classicCredentials(serverURL: url)
                return
            }
            switch SignInResolver.resolveClassic(serverURL: url, username: username, password: password) {
            case .failure(let error):
                addAccountError = Self.message(for: error)
            case .success(let resolved):
                await completeClassicSignIn(resolved)
            }
        }
    }

    /// Probe `serverURL`, reusing the server step's result when the field has not
    /// changed since — submitting the password should not re-probe the same server.
    private func probeResult(for serverURL: String) async -> BackendProbeResult {
        if let cached = probeForCurrentServer, cached.server == serverURL { return cached.result }
        guard let url = Self.normalizedURL(from: serverURL) else {
            return BackendProbeResult(hasOpenIDConfiguration: false, classicStatusJSON: nil)
        }
        let result = await prober.probe(serverURL: url)
        probeForCurrentServer = (serverURL, result)
        return result
    }

    /// Store the Basic credential and add the single Classic domain through
    /// ``DomainService`` — which records the account in the registry first, so it
    /// appears in the sidebar even if the domain add fails.
    private func completeClassicSignIn(_ resolved: ResolvedSignIn) async {
        KeychainCredentialStore(account: resolved.account, accessGroup: Self.keychainAccessGroup)
            .save(resolved.credentials)
        do {
            try await service.addSpace(resolved.syncRoot, displayName: resolved.account.displayName)
        } catch {
            addAccountError = Self.domainAddFailureMessage(error)
            return
        }
        await reload()
        selectedAccountID = resolved.account.accountIdentifier
        addAccountDidFinish = true
    }

    /// The oCIS sign-in (issue #17): the same chain `DevHarnessOCIS` proves live,
    /// with the real `ASWebAuthenticationSession` presenter in place of its scripted
    /// stand-in. Discovery → PKCE authorize in the system browser → code exchange →
    /// `me/drives` → ``OCISSignInResolver`` (personal space only; the rest are opted
    /// into from the Spaces tab) → Keychain + catalog + refresh parameters → domain.
    private func signInWithOIDC(serverURL: URL) async {
        addAccountFlow = .authorizing(serverURL: serverURL)
        let registration = OCISClientRegistration.ownCloudMobile
        let client = RemoteClient.urlSession()
        let presenter = WebAuthorizationPresenter(callbackScheme: registration.callbackScheme)

        do {
            let coordinator = OIDCSignInCoordinator(
                clientID: registration.clientID,
                clientSecret: registration.clientSecret,
                redirectURI: registration.redirectURI,
                scope: registration.scope,
                fetchDiscovery: { server in
                    try await client.send(
                        RemoteRequest(method: .get,
                                      url: server.appendingPathComponent(".well-known/openid-configuration")),
                        authorization: nil)
                },
                authorize: presenter.authorize,
                sendToken: { try await client.send($0, authorization: nil) })

            let success = try await coordinator.signIn(serverURL: serverURL)
            guard case .bearer(let accessToken, _, _) = success.credentials,
                  let idToken = success.idToken else {
                addAccountError = "The server’s sign-in response did not include the expected tokens."
                addAccountFlow = .server
                return
            }

            let claims = try await Self.identityClaims(
                idToken: idToken, configuration: success.configuration,
                accessToken: accessToken, client: client)

            let driveData = try await client.send(
                GraphRequestBuilder(baseURL: serverURL).listDrives(),
                authorization: "Bearer \(accessToken)")
            let resolved = try OCISSignInResolver.resolve(
                serverURL: serverURL,
                credentials: success.credentials,
                claims: claims,
                drives: try GraphJSONDecoder().decodeDriveList(driveData),
                spaces: .personalOnly)

            try await persistAndMount(resolved, configuration: success.configuration,
                                      registration: registration)
        } catch {
            addAccountError = Self.oidcMessage(for: error)
            addAccountFlow = .server
        }
    }

    /// The identity to name the account with: the `id_token`'s claims, enriched from the
    /// UserInfo endpoint when the server advertises one.
    ///
    /// This is not an optimisation — it is required for oCIS to be usable. Konnect's
    /// `id_token` carries only `sub`, so naming from the JWT alone labels the account
    /// with an opaque 80-character subject; `preferred_username` ("admin") lives only in
    /// the UserInfo response (OIDC Core §5.3).
    ///
    /// A UserInfo failure is deliberately **not** fatal: the `id_token`'s own claims are
    /// a valid, if uglier, identity, and losing a whole sign-in over a cosmetic lookup
    /// would be the wrong trade. A subject *mismatch* is swallowed here for the same
    /// reason — ``OIDCIDToken/merging(_:userInfoJSON:)`` has already refused to apply
    /// the other user's claims, which is the part that matters.
    private static func identityClaims(idToken: String,
                                       configuration: OIDCConfiguration,
                                       accessToken: String,
                                       client: RemoteClient) async throws -> OIDCIDTokenClaims {
        let claims = try OIDCIDToken.claims(from: idToken)
        guard let userInfoEndpoint = configuration.userInfoEndpoint else { return claims }
        do {
            let data = try await client.send(
                RemoteRequest(method: .get, url: userInfoEndpoint),
                authorization: "Bearer \(accessToken)")
            return try OIDCIDToken.merging(claims, userInfoJSON: data)
        } catch {
            return claims
        }
    }

    /// Persist everything a signed-in oCIS account needs across processes, then mount
    /// its space. Order matters: the credential and the refresh parameters must be in
    /// place *before* the domain exists, or the extension's first enumeration finds no
    /// authorization. The catalog is stored too — without it the Spaces tab would be
    /// empty until the next live `me/drives`.
    private func persistAndMount(_ resolved: ResolvedOCISSignIn,
                                 configuration: OIDCConfiguration,
                                 registration: OCISClientRegistration) async throws {
        let accountIdentifier = resolved.account.accountIdentifier
        KeychainCredentialStore(account: resolved.account, accessGroup: Self.keychainAccessGroup)
            .save(resolved.credentials)
        catalogCache.store(resolved.catalog, forAccount: accountIdentifier)
        sessionStore.store(
            OIDCSessionRecord(
                tokenEndpoint: configuration.tokenEndpoint,
                clientID: registration.clientID,
                clientSecret: registration.clientSecret,
                scope: registration.scope),
            forAccount: accountIdentifier)

        let names = DomainDisplayNamer.displayNames(for: resolved.syncRoots.map { root in
            DomainNameInput(
                syncRoot: root,
                spaceName: resolved.catalog.spaces.first { $0.driveID == root.driveID }?.name
                    ?? resolved.account.displayName)
        })
        for root in resolved.syncRoots {
            do {
                try await service.addSpace(
                    root, displayName: names[root.domainIdentifier] ?? resolved.account.displayName)
            } catch {
                addAccountError = Self.domainAddFailureMessage(error)
                addAccountFlow = .server
                return
            }
        }
        await reload()
        selectedAccountID = accountIdentifier
        addAccountDidFinish = true
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
        }
    }

    private static func domainAddFailureMessage(_ error: Error) -> String {
        "Could not add the account’s file provider domain: " + error.localizedDescription
    }

    /// A user-facing sentence for an oCIS sign-in failure. A cancelled browser sheet
    /// is the common case and is not an error worth alarming wording; the resolver's
    /// own failures name the actual problem; anything else falls back to the
    /// underlying description rather than a vague "sign-in failed".
    private static func oidcMessage(for error: Error) -> String {
        switch error {
        case let error as OCISSignInError:
            switch error {
            case .noPersonalSpace:
                return "This account has no personal space, so there is nothing to sync yet. "
                    + "Ask your administrator to enable one."
            case .noSpaces:
                return "This account has no spaces, so there is nothing to sync."
            case .notBearerCredentials:
                return "The server’s sign-in response did not include an access token."
            }
        case is OIDCIDTokenError:
            return "The server’s sign-in response could not be read (invalid ID token)."
        default:
            #if canImport(AuthenticationServices)
            if let error = error as? ASWebAuthenticationSessionError,
               error.code == .canceledLogin {
                return "Sign-in was cancelled."
            }
            #endif
            return "Sign-in failed: \(error.localizedDescription)"
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
    /// deep link from the UI extension (Task 7.9): select that account and re-run its
    /// sign-in.
    ///
    /// For oCIS this actually reconnects — a refresh token that the IDP has revoked or
    /// expired can only be replaced by a new authorization, so the browser sheet is
    /// presented again for the same server and the fresh tokens overwrite the stale
    /// ones under the same account identifier. Classic accounts need a typed password,
    /// so those still present the sheet for the user to fill in.
    func handleLaunch(_ url: URL) {
        guard case let .reconnect(accountIdentifier) = AppLaunchURL.parse(url) else { return }
        selectedAccountID = accountIdentifier
        guard let account = registry.accounts.first(where: { $0.accountIdentifier == accountIdentifier }),
              account.backend == .ocis else {
            // Classic: presenting the sign-in sheet is the same path beginAddAccount drives.
            return
        }
        Task { await signInWithOIDC(serverURL: account.serverURL) }
    }

    private static var appGroupContainerPath: String {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .path ?? NSTemporaryDirectory()
    }
}
