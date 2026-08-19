import XCTest
@testable import FileProviderSupport
@testable import OwnCloudCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Live contract tier for the **oCIS OIDC sign-in** (progress.md Tasks 7.8 / 7.12 /
/// 2.5 / 5.1-oCIS). It drives the *production* sign-in chain against the real oCIS
/// Konnect IDP in the Docker fixture:
///
///   `OIDCSignInCoordinator.signIn` (discovery → authorize → PKCE code exchange →
///   `OIDCTokenResponse` bearer credential + `id_token`)
///     → `DriveResolver.resolvePersonalDriveID` (`GET /me/drives` with the real
///       bearer token)
///     → `OCISSignInResolver.resolve` (identity from the `id_token`, one `SyncRoot`
///       per drive, `SpaceCatalog`)
///     → `OIDCTokenRequestBuilder.refresh` (a real `refresh_token` grant).
///
/// The one piece a headless test cannot present is the interactive browser consent —
/// `ASWebAuthenticationSession`. The coordinator already injects that as its
/// `authorize` closure (the Mac adapter is `WebAuthorizationPresenter`); here the
/// closure instead drives Konnect's scripted logon+authorize HTTP API, the standard
/// way OIDC end-to-end tests stand in for the browser. So every line of the sign-in
/// *decision + protocol* code runs against the live IDP; only the AppKit web sheet is
/// out of frame (its own GUI gate, like the Finder round-trip).
///
/// Gated on `OWNCLOUD_TEST_BACKEND=ocis`, so a plain `swift test` self-skips and it
/// runs on the oCIS backend-contract CI leg:
///   OWNCLOUD_TEST_BACKEND=ocis swift test --filter OCISSignInContract
final class OCISSignInContractTests: XCTestCase {

    private var serverURL: URL!
    private var session: URLSession!
    /// The **shipping** registration the settings UI signs in with (issue #17) — the
    /// native client id + secret + custom-scheme redirect oCIS registers by default.
    /// Exercising it here is the load-bearing proof that the app's client choice is
    /// one the live IDP actually accepts: lico matches a custom-scheme `redirect_uri`
    /// by string equality and requires the registered secret at the token endpoint,
    /// so a wrong value fails this test rather than only failing in the GUI.
    private let registration = OCISClientRegistration.ownCloudMobile
    private var clientID: String { registration.clientID }
    private var redirectURI: String { registration.redirectURI }
    private var scope: String { registration.scope }

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["OWNCLOUD_TEST_BACKEND"] == "ocis" else {
            throw XCTSkip("Set OWNCLOUD_TEST_BACKEND=ocis to run the oCIS sign-in contract tier.")
        }
        serverURL = URL(string: env["OWNCLOUD_TEST_URL"] ?? "https://localhost:9200")!
        // The Konnect SSO cookie is captured from the logon response and replayed by
        // hand on the authorize GET (URLSession's ephemeral store drops the
        // `__Secure-`-prefixed cookie, and its initializer is unavailable on
        // swift-corelibs-foundation), so no cookie storage is configured here.
        session = URLSession(
            configuration: .ephemeral,
            delegate: OCISInsecureTrustDelegate(),
            delegateQueue: nil)
    }

    override func tearDownWithError() throws {
        session?.finishTasksAndInvalidate()
    }

    /// The whole sign-in chain, against the live IDP, ending in a resolved account
    /// with one sync root per space and a bearer credential that actually authorizes
    /// the Graph API — then a real refresh grant renews it.
    func testFullOIDCSignInResolvesAccountAndSpacesLive() async throws {
        let user = ProcessInfo.processInfo.environment["OWNCLOUD_TEST_USER"] ?? "admin"
        let password = ProcessInfo.processInfo.environment["OWNCLOUD_TEST_PASSWORD"] ?? "admin"

        // Production coordinator: only the outside-world closures are injected. The
        // `authorize` closure is the scripted-browser stand-in.
        let session = self.session!
        let coordinator = OIDCSignInCoordinator(
            clientID: registration.clientID,
            clientSecret: registration.clientSecret,
            redirectURI: registration.redirectURI,
            scope: registration.scope,
            fetchDiscovery: { [self] server in
                try await self.get(server.appendingPathComponent(".well-known/openid-configuration"))
            },
            authorize: { [self] authorizationURL in
                try await self.scriptedBrowserSignIn(authorizationURL: authorizationURL, user: user, password: password)
            },
            sendToken: { request in
                let urlRequest = try URLRequestFactory.urlRequest(from: request, authorization: nil)
                let (data, response) = try await session.data(for: urlRequest)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            })

        // 1. Sign in through the production coordinator.
        let success = try await coordinator.signIn(serverURL: serverURL)
        guard case .bearer(let accessToken, let refreshToken, _) = success.credentials else {
            return XCTFail("sign-in must yield bearer credentials, got \(success.credentials)")
        }
        XCTAssertFalse(accessToken.isEmpty, "the live IDP must return an access token")
        XCTAssertFalse(refreshToken.isEmpty, "offline_access must return a refresh token")
        let idToken = try XCTUnwrap(success.idToken, "the live IDP must issue an id_token")

        // 2. The real bearer token authorizes the Graph API: list the user's drives
        //    through the production DriveResolver's client path.
        let client = RemoteClient.urlSession(session)
        let driveList = try await client.send(
            GraphRequestBuilder(baseURL: serverURL).listDrives(),
            authorization: "Bearer \(accessToken)")
        let drives = try GraphJSONDecoder().decodeDriveList(driveList)
        XCTAssertFalse(drives.isEmpty, "a signed-in oCIS user has at least a personal drive")
        XCTAssertNotNil(GraphDrive.personalDrive(in: drives), "there must be a personal space")

        // 2b. The account's *name*. Konnect's `id_token` carries only `sub` (verified
        //     below), so naming from the JWT alone labels the account with an opaque
        //     80-character subject — which is what shipped until this assertion existed.
        //     `preferred_username` comes from the UserInfo endpoint (OIDC Core §5.3).
        let tokenOnlyClaims = try OIDCIDToken.claims(from: idToken)
        XCTAssertNil(tokenOnlyClaims.preferredUsername,
                     "pins the reason UserInfo is needed: Konnect's id_token omits preferred_username")
        let userInfoEndpoint = try XCTUnwrap(success.configuration.userInfoEndpoint,
                                            "oCIS advertises a userinfo_endpoint in discovery")
        let claims = try OIDCIDToken.merging(
            tokenOnlyClaims,
            userInfoJSON: try await client.send(RemoteRequest(method: .get, url: userInfoEndpoint),
                                                authorization: "Bearer \(accessToken)"))
        XCTAssertEqual(claims.accountName, user,
                       "the live account is named by preferred_username, not the opaque subject")

        // 3. Resolve the completed sign-in into an account + sync roots.
        let resolved = try OCISSignInResolver.resolve(
            serverURL: serverURL,
            credentials: success.credentials,
            claims: claims,
            drives: drives)
        XCTAssertEqual(resolved.account.backend, .ocis)
        XCTAssertEqual(resolved.account.username, user, "the account is named from the merged claims")
        XCTAssertEqual(resolved.syncRoots.count, drives.count, "one sync root per space")
        XCTAssertEqual(resolved.catalog.spaces.count, drives.count)

        // 3b. What the settings UI actually signs in with (issue #17): the personal
        //     space alone becomes a domain, while the catalog still offers every
        //     space for the Spaces tab to opt into later.
        let personalOnly = try OCISSignInResolver.resolve(
            serverURL: serverURL,
            credentials: success.credentials,
            claims: claims,
            drives: drives,
            spaces: .personalOnly)
        XCTAssertEqual(personalOnly.syncRoots.count, 1, "personal-only mounts exactly one space")
        XCTAssertEqual(personalOnly.syncRoots.first?.driveID, GraphDrive.personalDrive(in: drives)?.id)
        XCTAssertEqual(personalOnly.catalog.spaces.count, drives.count,
                       "the catalog still lists every space")

        // 4. The refresh grant renews the bearer credential against the live IDP.
        let refreshRequest = OIDCTokenRequestBuilder(tokenEndpoint: success.configuration.tokenEndpoint)
            .refresh(refreshToken: refreshToken, clientID: registration.clientID,
                     clientSecret: registration.clientSecret, scope: registration.scope)
        let refreshData: Data = try await {
            let urlRequest = try URLRequestFactory.urlRequest(from: refreshRequest, authorization: nil)
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            return data
        }()
        let renewed = try OIDCTokenResponse.credentials(from: refreshData, now: Date(), previousRefreshToken: refreshToken)
        guard case .bearer(let renewedAccess, _, _) = renewed else {
            return XCTFail("refresh must yield bearer credentials, got \(renewed)")
        }
        XCTAssertFalse(renewedAccess.isEmpty, "the refresh grant must return a fresh access token")
    }

    /// The **extension's** refresh wiring, end to end against the live IDP (issue #17;
    /// the refresh half of Task 2.5).
    ///
    /// oCIS access tokens carry `expires_in=300`, so without this the domain stops
    /// working five minutes after sign-in. The test builds exactly what
    /// `FileProviderExtension.authorization(for:)` builds — a `SessionManager` over a
    /// credential store, with `OIDCRefreshHandler` driven by the blocking
    /// `SynchronousTokenSender` and a `FileLock` — seeds a token that is *already*
    /// stale, and asserts the manager renews it against Konnect and persists the
    /// result. That proves the wiring now rather than after a five-minute wait.
    ///
    /// The one substitution is the credential store: an in-memory double instead of
    /// the Keychain, whose own round-trip is covered by `KeychainCredentialStoreTests`.
    func testExtensionRefreshWiringRenewsAStaleTokenLive() async throws {
        let user = ProcessInfo.processInfo.environment["OWNCLOUD_TEST_USER"] ?? "admin"
        let password = ProcessInfo.processInfo.environment["OWNCLOUD_TEST_PASSWORD"] ?? "admin"
        let session = self.session!

        let coordinator = OIDCSignInCoordinator(
            clientID: registration.clientID,
            clientSecret: registration.clientSecret,
            redirectURI: registration.redirectURI,
            scope: registration.scope,
            fetchDiscovery: { [self] server in
                try await self.get(server.appendingPathComponent(".well-known/openid-configuration"))
            },
            authorize: { [self] authorizationURL in
                try await self.scriptedBrowserSignIn(
                    authorizationURL: authorizationURL, user: user, password: password)
            },
            sendToken: { request in
                let urlRequest = try URLRequestFactory.urlRequest(from: request, authorization: nil)
                let (data, response) = try await session.data(for: urlRequest)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            })

        let success = try await coordinator.signIn(serverURL: serverURL)
        guard case .bearer(let accessToken, let refreshToken, _) = success.credentials else {
            return XCTFail("sign-in must yield bearer credentials, got \(success.credentials)")
        }

        // Seed the store with a token that has already expired, so the manager's own
        // staleness decision (not the test's) triggers the refresh.
        let store = InMemoryCredentialStore()
        store.save(.bearer(accessToken: accessToken, refreshToken: refreshToken,
                           expiresAt: Date(timeIntervalSince1970: 0)))

        // The production wiring, verbatim.
        let sender = SynchronousTokenSender(session: session)
        let manager = SessionManager(
            store: store,
            refresh: OIDCRefreshHandler.make(
                tokenEndpoint: success.configuration.tokenEndpoint,
                clientID: registration.clientID,
                clientSecret: registration.clientSecret,
                scope: registration.scope,
                send: sender.send),
            refreshLock: FileLock(path: NSTemporaryDirectory() + "ocis-contract-refresh.lock"))
        XCTAssertTrue(manager.needsTokenRefresh(), "the seeded token is expired")

        // `refreshTokenIfNeeded` blocks (that is the point of the synchronous sender),
        // so run it off the cooperative pool.
        try await Task.detached { try manager.refreshTokenIfNeeded() }.value

        XCTAssertFalse(manager.needsTokenRefresh(), "the renewed token must no longer be stale")
        guard case .bearer(let renewedAccess, let renewedRefresh, let expiresAt) = try XCTUnwrap(store.load()) else {
            return XCTFail("the refreshed credential must be persisted as bearer")
        }
        XCTAssertFalse(renewedAccess.isEmpty)
        XCTAssertFalse(renewedRefresh.isEmpty, "a refresh token is retained even if the IDP omits a new one")
        XCTAssertGreaterThan(expiresAt, Date(), "the renewed token expires in the future")

        // And the renewed token really authorizes the API — the whole point.
        let header = try manager.authorizationHeader()
        XCTAssertEqual(header, "Bearer \(renewedAccess)")
        let driveList = try await RemoteClient.urlSession(session).send(
            GraphRequestBuilder(baseURL: serverURL).listDrives(), authorization: header)
        XCTAssertFalse(try GraphJSONDecoder().decodeDriveList(driveList).isEmpty)
    }

    // MARK: - Scripted browser stand-in (Konnect logon + authorize)

    /// Stands in for `ASWebAuthenticationSession`: establishes the Konnect SSO
    /// session by POSTing the credentials to its logon API, grants consent, then
    /// follows the authorization URL and returns the redirect callback URL carrying
    /// `?code=…`. Everything the coordinator does around this — building the authorize
    /// URL with PKCE/state, validating state, redeeming the code — is the production
    /// path.
    ///
    /// The consent leg is required because the registered mobile client is
    /// `trusted: false` in oCIS's shipped registration, so lico forces a consent
    /// prompt (`identity/managers/identifier.go`: *"If not trusted, always force
    /// consent"*). In the product that is one extra tap in the browser sheet; here it
    /// is the scripted equivalent. Without it, authorize redirects back to the sign-in
    /// form with `flow=consent` instead of to the callback, which is exactly the
    /// `missingCode` failure this stand-in must not paper over.
    private func scriptedBrowserSignIn(authorizationURL: URL, user: String, password: String) async throws -> URL {
        let sessionCookie = try await konnectLogon(user: user, password: password)
        // The consent cookie's *name* is a hash over (konnect state, client id, raw
        // redirect uri, the OAuth `state`, nonce), so the grant has to be minted for
        // this very authorization request — hence the state is read back out of the
        // URL the coordinator built.
        let oauthState = try XCTUnwrap(
            URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "state" }?.value,
            "the production authorize URL always carries a state")
        let konnectState = "scripted-consent"
        let consentCookie = try await konnectConsent(
            konnectState: konnectState, oauthState: oauthState, sessionCookie: sessionCookie)

        // Follow the authorize URL with no redirect handling so we can read the
        // Location header the IDP returns once it has an authenticated session. Both
        // Konnect cookies (`__Secure-KKT`, `__Secure-KKTC-…`) are replayed by hand —
        // URLSession's ephemeral storage silently drops `__Secure-`-prefixed cookies.
        // `konnect=<state>` is what the sign-in UI itself appends to point the
        // authorize call at the consent grant.
        var components = try XCTUnwrap(
            URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false))
        components.queryItems = (components.queryItems ?? [])
            + [URLQueryItem(name: "konnect", value: konnectState)]
        var request = URLRequest(url: try XCTUnwrap(components.url))
        request.httpMethod = "GET"
        request.setValue("\(sessionCookie); \(consentCookie)", forHTTPHeaderField: "Cookie")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let location = http.value(forHTTPHeaderField: "Location"),
              let callback = URL(string: location) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "authorize returned no redirect (status \(code))"])
        }
        return callback
    }

    /// Grant consent for this authorization request and return the short-lived
    /// consent cookie (`name=value`) the authorize call must replay.
    private func konnectConsent(konnectState: String,
                                oauthState: String,
                                sessionCookie: String) async throws -> String {
        var request = URLRequest(url: serverURL.appendingPathComponent("signin/v1/identifier/_/consent"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Kopano-Konnect-XSRF")
        request.setValue(serverURL.appendingPathComponent("signin/v1/identifier").absoluteString,
                         forHTTPHeaderField: "Referer")
        request.setValue(sessionCookie, forHTTPHeaderField: "Cookie")
        let payload: [String: Any] = [
            "state": konnectState,
            "allow": true,
            "scope": scope,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            // lico's `ref` is the OAuth `state`; `flow_nonce` is the (unused) nonce.
            "ref": oauthState,
            "flow_nonce": "",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["success"] as? Bool == true else {
            throw URLError(.userAuthenticationRequired,
                           userInfo: [NSLocalizedDescriptionKey: "Konnect consent was not granted"])
        }
        guard let setCookie = http.value(forHTTPHeaderField: "Set-Cookie"),
              let pair = setCookie.split(separator: ";").first else {
            throw URLError(.userAuthenticationRequired,
                           userInfo: [NSLocalizedDescriptionKey: "Konnect consent set no cookie"])
        }
        return String(pair)
    }

    /// POST the credentials to Konnect's identifier logon endpoint and return the SSO
    /// session cookie (`name=value`) the subsequent authorize call must replay.
    private func konnectLogon(user: String, password: String) async throws -> String {
        var request = URLRequest(url: serverURL.appendingPathComponent("signin/v1/identifier/_/logon"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Kopano-Konnect-XSRF")
        request.setValue(serverURL.appendingPathComponent("signin/v1/identifier").absoluteString, forHTTPHeaderField: "Referer")
        let payload: [String: Any] = [
            "params": [user, password, "1"],
            "hello": [
                "scope": scope,
                "client_id": clientID,
                "redirect_uri": redirectURI,
                "flow": "oidc",
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["success"] as? Bool == true else {
            throw URLError(.userAuthenticationRequired, userInfo: [NSLocalizedDescriptionKey: "Konnect logon failed"])
        }
        // The `Set-Cookie` header is `name=value; Path=…; Secure; …` — keep just the
        // `name=value` pair to replay as the request `Cookie`.
        guard let setCookie = http.value(forHTTPHeaderField: "Set-Cookie"),
              let pair = setCookie.split(separator: ";").first else {
            throw URLError(.userAuthenticationRequired, userInfo: [NSLocalizedDescriptionKey: "Konnect logon set no session cookie"])
        }
        return String(pair)
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

/// Stands in for the Keychain in the refresh-wiring test, whose subject is
/// `SessionManager` + the live token endpoint, not storage (the Keychain's own
/// round-trip is covered by `KeychainCredentialStoreTests`).
private final class InMemoryCredentialStore: CredentialStore {
    private var credentials: Credentials?
    func load() -> Credentials? { credentials }
    func save(_ credentials: Credentials) { self.credentials = credentials }
    func clear() { credentials = nil }
}

/// Trusts the fixture's self-signed certificate and, crucially, does **not** follow
/// the authorize redirect — the `?code=…` callback must be read from the `Location`
/// header, not chased to the server root. Test-only; a distinct name avoids a symbol
/// clash with `OIDCDiscoveryContractTests`.
private final class OCISInsecureTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        #if canImport(Security)
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        #endif
        completionHandler(.performDefaultHandling, nil)
    }

    /// Returning `nil` stops the redirect and hands back the 3xx response itself, so
    /// the caller can read its `Location` header (the OAuth callback with the code).
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
