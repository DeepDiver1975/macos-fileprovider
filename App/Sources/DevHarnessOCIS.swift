#if DEBUG
import SwiftUI
import FileProvider
import OwnCloudCore
import FileProviderSupport
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Debug-only oCIS counterpart of ``DevHarnessModel`` (progress.md Tasks 5.1 / 4.1
/// / 4.2, oCIS legs). The Classic harness proves a path-addressed WebDAV domain in
/// Finder; this one exercises the **ID-addressed** oCIS path — `me/drives` → one
/// domain per drive → `PROPFIND` Depth:1 on the space → `GET /dav/spaces/{oc:id}`.
/// Graph's role ends at the drive listing (Task 4.5).
///
/// Sign-in goes through the *production* ``OIDCSignInCoordinator`` and
/// ``OCISSignInResolver``. The one injected seam is the `authorize` closure: instead
/// of presenting `ASWebAuthenticationSession` (the GUI gate), it drives Konnect's
/// scripted logon+authorize HTTP API — the exact stand-in the passing
/// `OCISSignInContractTests` uses. So every sign-in *decision* runs the shipping
/// code; only the web sheet is out of frame.
///
/// The extension wires a refresh-less `SessionManager` (Task 2.5 remainder), so the
/// seeded bearer token is valid only within its initial ~5-minute window — enough
/// for a first mount + enumerate + download, which is the untested leg here.
@MainActor
final class DevHarnessOCISModel: ObservableObject {
    @Published var status: String = "Idle"

    static let keychainAccessGroup = "com.owncloud.macos.fileprovider.shared"
    static let serverURL = URL(string: "https://localhost:9200")!
    static let clientID = "web"
    static let scope = "openid profile email offline_access"
    static let user = "admin"
    static let password = "admin"

    /// Redirect URI the oCIS `web` client registers; the exchange only needs an
    /// exact match, so the server root is reused (as in the contract test).
    private var redirectURI: String { Self.serverURL.absoluteString + "/" }

    /// Trusts the fixture's self-signed cert and refuses the authorize redirect so
    /// the `?code=` can be read from the `Location` header. Test/harness-only.
    private lazy var session: URLSession = URLSession(
        configuration: .ephemeral,
        delegate: HarnessInsecureTrustDelegate(),
        delegateQueue: nil)

    /// The sync roots resolved at sign-in, so Add/Remove operate on the same set.
    private var resolvedRoots: [SyncRoot] = []
    private var resolvedAccount: AccountDescriptor?

    /// Non-interactive driver for a headless-machine live run (launch the app with
    /// `-ocis-autorun 1`): sign in, add every domain, and log each step to unified
    /// logging (`log stream --predicate 'eventMessage CONTAINS "[DevHarnessOCIS]"'`).
    /// The domains are left mounted so Finder enumeration/download can be verified.
    func autorun() async {
        var lines: [String] = ["autorun begin"]
        func record(_ s: String) { NSLog("[DevHarnessOCIS] %@", s); lines.append(s); writeReport(lines) }

        await signInAsync()
        record("after sign-in: \(status)")
        guard resolvedAccount != nil, !resolvedRoots.isEmpty else {
            record("autorun abort — no resolved roots")
            return
        }
        // Remove any domains left from a previous run so this one gets a fresh
        // enumeration with no cached failure/backoff, then re-add.
        await removeDomainsAsync()
        record("after remove-domains: \(status)")
        await addDomainsAsync()
        record("after add-domains: \(status)")
        for root in resolvedRoots {
            record("domain identifier=\(root.domainIdentifier) driveID=\(root.driveID ?? "nil")")
        }
        record("autorun complete")
    }

    /// Write the autorun transcript into the app-group container, which a process
    /// outside the sandbox can read to verify the live run.
    private func writeReport(_ lines: [String]) {
        guard let dir = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroup.identifier) else { return }
        let url = dir.appendingPathComponent("ocis-autorun-report.txt")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Sign in through the production coordinator, list drives with the real bearer
    /// token, resolve the account + one sync root per drive, and persist the bearer
    /// credential in the shared Keychain so the extension's `authorization(for:)`
    /// resolves a header.
    func signIn() { Task { await signInAsync() } }

    private func signInAsync() async {
        status = "Signing in to oCIS…"
        do {
                let coordinator = OIDCSignInCoordinator(
                    clientID: Self.clientID,
                    redirectURI: redirectURI,
                    scope: Self.scope,
                    fetchDiscovery: { [self] server in
                        try await get(server.appendingPathComponent(".well-known/openid-configuration"))
                    },
                    authorize: { [self] authorizationURL in
                        try await scriptedBrowserSignIn(authorizationURL: authorizationURL)
                    },
                    sendToken: { [self] request in
                        try await sendForm(request)
                    })

                let success = try await coordinator.signIn(serverURL: Self.serverURL)
                guard case .bearer(let accessToken, _, _) = success.credentials,
                      let idToken = success.idToken else {
                    status = "Sign-in did not yield bearer credentials"
                    return
                }

                let client = RemoteClient.urlSession(session)
                let driveData = try await client.send(
                    GraphRequestBuilder(baseURL: Self.serverURL).listDrives(),
                    authorization: "Bearer \(accessToken)")
                let drives = try GraphJSONDecoder().decodeDriveList(driveData)

                let resolved = try OCISSignInResolver.resolve(
                    serverURL: Self.serverURL,
                    credentials: success.credentials,
                    idToken: idToken,
                    drives: drives)

                // Persist the bearer credential under the account's stable id so the
                // extension (same access group) resolves it.
                KeychainCredentialStore(account: resolved.account, accessGroup: Self.keychainAccessGroup)
                    .save(resolved.credentials)

                resolvedAccount = resolved.account
                resolvedRoots = resolved.syncRoots
                let names = drives.map(\.name).joined(separator: ", ")
            status = "Signed in as \(resolved.account.displayName). "
                + "\(resolved.syncRoots.count) drive(s): \(names). Now Add domains."
        } catch {
            status = "oCIS sign-in FAILED: \(error)"
        }
    }

    /// Register one domain per resolved drive (Task 7.4: one domain per space).
    func addDomains() { Task { await addDomainsAsync() } }

    private func addDomainsAsync() async {
        guard let account = resolvedAccount, !resolvedRoots.isEmpty else {
            status = "Sign in first."
            return
        }
        var added = 0
        for root in resolvedRoots {
            let displayName = driveDisplayName(for: root, account: account)
            let domain = NSFileProviderDomain(syncRoot: root, displayName: displayName)
            do {
                try await NSFileProviderManager.add(domain)
                added += 1
            } catch {
                status = "Add domain FAILED for \(displayName): \(error)"
                return
            }
        }
        status = "Added \(added) oCIS domain(s). Look in Finder's sidebar; open one to enumerate."
    }

    /// Remove every oCIS domain the system currently has. Uses `.removeAll` (not the
    /// sign-out default `.preserveDownloadedUserData`) so each harness run starts from
    /// a clean local FileProvider cache — otherwise a re-add reuses the previous run's
    /// cached (possibly stale) root enumeration and the extension is never hit.
    func removeDomains() { Task { await removeDomainsAsync() } }

    private func removeDomainsAsync() async {
        let domains = (try? await NSFileProviderManager.domains()) ?? []
        var removed = 0
        for domain in domains {
            guard let root = SyncRoot(domainIdentifier: domain.identifier.rawValue),
                  root.account.backend == .ocis else { continue }
            _ = try? await NSFileProviderManager.remove(domain, mode: DomainRemovalChoice.removeAll.removalMode)
            removed += 1
        }
        status = "Removed \(removed) oCIS domain(s)."
    }

    /// Clear the stored bearer credential.
    func signOut() {
        guard let account = resolvedAccount else { status = "Not signed in."; return }
        KeychainCredentialStore(account: account, accessGroup: Self.keychainAccessGroup).clear()
        status = "Credential cleared."
    }

    private func driveDisplayName(for root: SyncRoot, account: AccountDescriptor) -> String {
        "\(account.displayName) · \(root.driveID.map { String($0.prefix(8)) } ?? "drive")"
    }

    // MARK: - Scripted browser stand-in (Konnect logon + authorize)

    private func scriptedBrowserSignIn(authorizationURL: URL) async throws -> URL {
        let sessionCookie = try await konnectLogon()
        var request = URLRequest(url: authorizationURL)
        request.httpMethod = "GET"
        request.setValue(sessionCookie, forHTTPHeaderField: "Cookie")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let location = http.value(forHTTPHeaderField: "Location"),
              let callback = URL(string: location) else {
            throw URLError(.badServerResponse)
        }
        return callback
    }

    private func konnectLogon() async throws -> String {
        var request = URLRequest(url: Self.serverURL.appendingPathComponent("signin/v1/identifier/_/logon"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Kopano-Konnect-XSRF")
        request.setValue(Self.serverURL.appendingPathComponent("signin/v1/identifier").absoluteString,
                         forHTTPHeaderField: "Referer")
        let payload: [String: Any] = [
            "params": [Self.user, Self.password, "1"],
            "hello": ["scope": Self.scope, "client_id": Self.clientID,
                      "redirect_uri": redirectURI, "flow": "oidc"],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["success"] as? Bool == true,
              let setCookie = http.value(forHTTPHeaderField: "Set-Cookie"),
              let pair = setCookie.split(separator: ";").first else {
            throw URLError(.userAuthenticationRequired)
        }
        return String(pair)
    }

    private func sendForm(_ request: RemoteRequest) async throws -> Data {
        let urlRequest = try URLRequestFactory.urlRequest(from: request, authorization: nil)
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

/// Trusts the fixture's self-signed cert and stops the authorize redirect so the
/// `?code=` callback is read from `Location`. Harness-only; production pins/validates
/// the real certificate and presents the real browser sheet.
private final class HarnessInsecureTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct DevHarnessOCISView: View {
    @StateObject private var model = DevHarnessOCISModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Local test harness — oCIS (DEBUG)")
                .font(.headline)
            Text("oCIS fixture · https://localhost:9200 · scripted OIDC")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Sign in", action: model.signIn)
                Button("Add domains", action: model.addDomains)
                Button("Remove domains", action: model.removeDomains)
                Button("Sign out", action: model.signOut)
            }
            Text(model.status)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(minWidth: 460)
    }
}
#endif
