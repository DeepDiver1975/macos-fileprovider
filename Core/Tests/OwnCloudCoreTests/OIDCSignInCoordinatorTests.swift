import XCTest
@testable import OwnCloudCore

/// The orchestration of the oCIS OIDC sign-in flow (Task 7.8), composing the pure
/// pieces — discovery, PKCE, authorization, code exchange — into one async result.
///
/// The two things a test cannot do (fetch bytes over the network, present a browser
/// window) are injected closures, exactly as `OIDCRefreshHandler` injects `send`.
/// The random `state`/verifier are injected too so the whole flow is deterministic.
/// This proves the wiring end to end without a network or a UI.
final class OIDCSignInCoordinatorTests: XCTestCase {

    private let discoveryJSON = Data("""
    {
      "issuer": "https://ocis.test",
      "authorization_endpoint": "https://ocis.test/idp/authorize",
      "token_endpoint": "https://ocis.test/idp/token"
    }
    """.utf8)

    func testHappyPathProducesBearerCredentialsAndConfiguration() async throws {
        var presentedURL: URL?
        var sentRequest: RemoteRequest?

        let coordinator = OIDCSignInCoordinator(
            clientID: "web",
            redirectURI: "oc://ios.owncloud.com",
            scope: "openid offline_access email",
            now: { Date(timeIntervalSince1970: 1000) },
            generateState: { "state-123" },
            generateVerifier: { "verifier-xyz" },
            fetchDiscovery: { serverURL in
                XCTAssertEqual(serverURL, URL(string: "https://ocis.test"))
                return self.discoveryJSON
            },
            authorize: { url in
                // The Mac adapter would present this in ASWebAuthenticationSession;
                // here we assert it and return the IDP's redirect callback.
                presentedURL = url
                return URL(string: "oc://ios.owncloud.com?code=the-code&state=state-123")!
            },
            sendToken: { request in
                sentRequest = request
                return Data("""
                {"access_token":"at","refresh_token":"rt","expires_in":3600}
                """.utf8)
            })

        let result = try await coordinator.signIn(serverURL: URL(string: "https://ocis.test")!)

        // Credentials are the bearer tokens, with expiry resolved against `now`.
        XCTAssertEqual(result.credentials, .bearer(
            accessToken: "at", refreshToken: "rt",
            expiresAt: Date(timeIntervalSince1970: 4600)))
        // The discovered configuration is returned so refresh can be wired to it.
        XCTAssertEqual(result.configuration.tokenEndpoint,
                       URL(string: "https://ocis.test/idp/token"))

        // The presented URL carried the PKCE challenge for our injected verifier.
        let presentedItems = URLComponents(url: presentedURL!, resolvingAgainstBaseURL: false)!.queryItems!
        let challenge = presentedItems.first { $0.name == "code_challenge" }?.value
        XCTAssertEqual(challenge, PKCE.challengeS256(for: "verifier-xyz"))

        // The token POST redeemed the code with the matching verifier.
        let body = String(data: sentRequest?.jsonBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("grant_type=authorization_code"), body)
        XCTAssertTrue(body.contains("code=the-code"), body)
        XCTAssertTrue(body.contains("code_verifier=verifier-xyz"), body)
    }

    func testPropagatesStateMismatchFromCallback() async {
        let coordinator = OIDCSignInCoordinator(
            clientID: "web", redirectURI: "oc://ios.owncloud.com", scope: "openid",
            now: { Date(timeIntervalSince1970: 0) },
            generateState: { "expected" },
            generateVerifier: { "v" },
            fetchDiscovery: { _ in self.discoveryJSON },
            authorize: { _ in URL(string: "oc://ios.owncloud.com?code=c&state=tampered")! },
            sendToken: { _ in XCTFail("must not exchange on a bad callback"); return Data() })

        do {
            _ = try await coordinator.signIn(serverURL: URL(string: "https://ocis.test")!)
            XCTFail("expected a state-mismatch error")
        } catch {
            XCTAssertEqual(error as? OIDCAuthorizationError, .stateMismatch)
        }
    }
}
