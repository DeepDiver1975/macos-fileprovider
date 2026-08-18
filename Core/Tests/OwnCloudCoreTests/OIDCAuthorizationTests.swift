import XCTest
@testable import OwnCloudCore

/// The authorization-request half of the oCIS OIDC sign-in flow (Task 7.8): build
/// the URL the user is sent to (`ASWebAuthenticationSession` loads it), then parse
/// the redirect the IDP returns to our custom scheme. Both are pure and fully
/// pinned here; the Mac adapter only presents the URL and hands back the callback.
final class OIDCAuthorizationTests: XCTestCase {

    private let config = OIDCConfiguration(
        issuer: URL(string: "https://ocis.test")!,
        authorizationEndpoint: URL(string: "https://ocis.test/idp/authorize")!,
        tokenEndpoint: URL(string: "https://ocis.test/idp/token")!)

    // MARK: Building the authorization URL

    func testAuthorizationURLCarriesPKCEAndRequiredParameters() throws {
        let request = OIDCAuthorizationRequest(
            configuration: config,
            clientID: "web",
            redirectURI: "oc://ios.owncloud.com",
            scope: "openid offline_access email",
            state: "state-123",
            codeChallenge: "challenge-abc")

        let url = request.authorizationURL
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "ocis.test")
        XCTAssertEqual(components.path, "/idp/authorize")
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["client_id"], "web")
        XCTAssertEqual(items["redirect_uri"], "oc://ios.owncloud.com")
        XCTAssertEqual(items["scope"], "openid offline_access email")
        XCTAssertEqual(items["state"], "state-123")
        XCTAssertEqual(items["code_challenge"], "challenge-abc")
        XCTAssertEqual(items["code_challenge_method"], "S256")
    }

    // MARK: Parsing the redirect callback

    func testParsesAuthorizationCodeWhenStateMatches() throws {
        let callback = URL(string: "oc://ios.owncloud.com?code=auth-code-xyz&state=state-123")!
        let code = try OIDCAuthorizationRequest.authorizationCode(
            fromCallback: callback, expectedState: "state-123")
        XCTAssertEqual(code, "auth-code-xyz")
    }

    func testRejectsCallbackWhenStateDoesNotMatch() {
        let callback = URL(string: "oc://ios.owncloud.com?code=auth-code-xyz&state=tampered")!
        XCTAssertThrowsError(try OIDCAuthorizationRequest.authorizationCode(
            fromCallback: callback, expectedState: "state-123")) { error in
            XCTAssertEqual(error as? OIDCAuthorizationError, .stateMismatch)
        }
    }

    func testSurfacesServerReportedError() {
        let callback = URL(string: "oc://ios.owncloud.com?error=access_denied&state=state-123")!
        XCTAssertThrowsError(try OIDCAuthorizationRequest.authorizationCode(
            fromCallback: callback, expectedState: "state-123")) { error in
            XCTAssertEqual(error as? OIDCAuthorizationError, .server("access_denied"))
        }
    }

    func testRejectsCallbackWithNoCode() {
        let callback = URL(string: "oc://ios.owncloud.com?state=state-123")!
        XCTAssertThrowsError(try OIDCAuthorizationRequest.authorizationCode(
            fromCallback: callback, expectedState: "state-123")) { error in
            XCTAssertEqual(error as? OIDCAuthorizationError, .missingCode)
        }
    }
}
