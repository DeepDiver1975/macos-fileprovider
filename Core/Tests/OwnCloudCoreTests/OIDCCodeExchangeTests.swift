import XCTest
@testable import OwnCloudCore

/// The token-exchange half of the oCIS OIDC sign-in flow (Task 7.8): once the
/// browser hands back an authorization code, redeem it at the token endpoint with
/// the PKCE `code_verifier`. This pins the form-encoded `authorization_code` POST;
/// the response is parsed by the already-tested `OIDCTokenResponse.credentials`.
final class OIDCCodeExchangeTests: XCTestCase {

    private let tokenEndpoint = URL(string: "https://ocis.test/idp/token")!

    func testBuildsAuthorizationCodeGrant() {
        let builder = OIDCTokenRequestBuilder(tokenEndpoint: tokenEndpoint)
        let request = builder.exchange(
            code: "auth code/+=",
            redirectURI: "oc://ios.owncloud.com",
            clientID: "web",
            codeVerifier: "verifier-123")

        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.url, tokenEndpoint)
        XCTAssertEqual(request.headers["Content-Type"], "application/x-www-form-urlencoded")

        let body = String(data: request.jsonBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("grant_type=authorization_code"), body)
        XCTAssertTrue(body.contains("redirect_uri=oc%3A%2F%2Fios.owncloud.com"), body)
        XCTAssertTrue(body.contains("client_id=web"), body)
        XCTAssertTrue(body.contains("code_verifier=verifier-123"), body)
        // Reserved characters in the code must be percent-encoded, not sent raw.
        XCTAssertTrue(body.contains("code=auth%20code%2F%2B%3D"), body)
    }
}
