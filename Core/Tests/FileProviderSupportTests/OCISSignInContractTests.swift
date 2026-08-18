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
    private let clientID = "web"
    // The oCIS `web` client registers `https://localhost:9200/` (among others) as a
    // redirect URI; the callback body is irrelevant to the token exchange beyond the
    // exact-match requirement, so reuse the server root.
    private var redirectURI: String { serverURL.absoluteString.hasSuffix("/") ? serverURL.absoluteString : serverURL.absoluteString + "/" }
    private let scope = "openid profile email offline_access"

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["OWNCLOUD_TEST_BACKEND"] == "ocis" else {
            throw XCTSkip("Set OWNCLOUD_TEST_BACKEND=ocis to run the oCIS sign-in contract tier.")
        }
        serverURL = URL(string: env["OWNCLOUD_TEST_URL"] ?? "https://localhost:9200")!
        // A shared cookie jar so the scripted logon's SSO session carries into the
        // authorize redirect, exactly as a browser would.
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = HTTPCookieStorage()
        config.httpCookieAcceptPolicy = .always
        session = URLSession(configuration: config, delegate: OCISInsecureTrustDelegate(), delegateQueue: nil)
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
            clientID: clientID,
            redirectURI: redirectURI,
            scope: scope,
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

        // 3. Resolve the completed sign-in into an account + sync roots.
        let resolved = try OCISSignInResolver.resolve(
            serverURL: serverURL,
            credentials: success.credentials,
            idToken: idToken,
            drives: drives)
        XCTAssertEqual(resolved.account.backend, .ocis)
        XCTAssertFalse(resolved.account.username.isEmpty, "the account is named from the id_token claims")
        XCTAssertEqual(resolved.syncRoots.count, drives.count, "one sync root per space")
        XCTAssertEqual(resolved.catalog.spaces.count, drives.count)

        // 4. The refresh grant renews the bearer credential against the live IDP.
        let refreshRequest = OIDCTokenRequestBuilder(tokenEndpoint: success.configuration.tokenEndpoint)
            .refresh(refreshToken: refreshToken, clientID: clientID, scope: scope)
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

    // MARK: - Scripted browser stand-in (Konnect logon + authorize)

    /// Stands in for `ASWebAuthenticationSession`: establishes the Konnect SSO
    /// session by POSTing the credentials to its logon API, then follows the
    /// authorization URL and returns the redirect callback URL carrying `?code=…`.
    /// Everything the coordinator does around this — building the authorize URL with
    /// PKCE/state, validating state, redeeming the code — is the production path.
    private func scriptedBrowserSignIn(authorizationURL: URL, user: String, password: String) async throws -> URL {
        let sessionCookie = try await konnectLogon(user: user, password: password)

        // Follow the authorize URL with no redirect handling so we can read the
        // Location header the IDP returns once it has an authenticated session. The
        // Konnect session cookie (`__Secure-KKT`) is replayed by hand — URLSession's
        // ephemeral storage silently drops the `__Secure-`-prefixed cookie.
        var request = URLRequest(url: authorizationURL)
        request.httpMethod = "GET"
        request.setValue(sessionCookie, forHTTPHeaderField: "Cookie")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let location = http.value(forHTTPHeaderField: "Location"),
              let callback = URL(string: location) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "authorize returned no redirect (status \(code))"])
        }
        return callback
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
