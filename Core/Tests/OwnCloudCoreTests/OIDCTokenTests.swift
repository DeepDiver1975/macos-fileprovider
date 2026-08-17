import XCTest
@testable import OwnCloudCore

/// Task 2.5 (remaining): the OIDC token-endpoint refresh for oCIS bearer tokens.
///
/// The testable surface is pure request shaping and response parsing — the same
/// split every other backend piece uses. `OIDCTokenRequestBuilder` shapes the
/// OAuth2 `refresh_token` grant (a form-urlencoded POST to the token endpoint),
/// and `OIDCTokenResponse` decodes the token JSON into `Credentials.bearer`,
/// turning the relative `expires_in` into an absolute expiry against an injected
/// clock. The live round-trip (discovery of the token endpoint + the actual POST)
/// is Mac/Task 6.0-gated.
final class OIDCTokenTests: XCTestCase {

    private let tokenEndpoint = URL(string: "https://ocis.test/konnect/token")!

    // MARK: - Request shaping

    func testRefreshRequestIsFormEncodedPOST() {
        let builder = OIDCTokenRequestBuilder(tokenEndpoint: tokenEndpoint)

        let request = builder.refresh(refreshToken: "rt-abc", clientID: "web", scope: nil)

        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.url, tokenEndpoint)
        XCTAssertEqual(request.headers["Content-Type"], "application/x-www-form-urlencoded")
        XCTAssertTrue(request.hasBody)

        let body = String(data: request.jsonBody ?? Data(), encoding: .utf8) ?? ""
        let pairs = Set(body.split(separator: "&").map(String.init))
        XCTAssertTrue(pairs.contains("grant_type=refresh_token"), body)
        XCTAssertTrue(pairs.contains("refresh_token=rt-abc"), body)
        XCTAssertTrue(pairs.contains("client_id=web"), body)
        XCTAssertFalse(body.contains("scope="), "scope omitted when nil: \(body)")
    }

    func testRefreshRequestPercentEncodesValuesAndIncludesScope() {
        let builder = OIDCTokenRequestBuilder(tokenEndpoint: tokenEndpoint)

        let request = builder.refresh(refreshToken: "rt/with+special=chars", clientID: "web", scope: "openid offline_access")

        let body = String(data: request.jsonBody ?? Data(), encoding: .utf8) ?? ""
        let pairs = Set(body.split(separator: "&").map(String.init))
        // Reserved characters must be escaped so the form parses correctly.
        XCTAssertTrue(pairs.contains("refresh_token=rt%2Fwith%2Bspecial%3Dchars"), body)
        XCTAssertTrue(pairs.contains("scope=openid%20offline_access"), body)
    }

    // MARK: - Response parsing

    func testDecodesTokenResponseIntoBearerCredentials() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let json = Data("""
        { "access_token": "new-at", "refresh_token": "new-rt", "expires_in": 3600, "token_type": "Bearer" }
        """.utf8)

        let credentials = try OIDCTokenResponse.credentials(from: json, now: now, previousRefreshToken: "old-rt")

        XCTAssertEqual(
            credentials,
            .bearer(accessToken: "new-at", refreshToken: "new-rt", expiresAt: now.addingTimeInterval(3600))
        )
    }

    func testFallsBackToPreviousRefreshTokenWhenResponseOmitsOne() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        // Per OAuth2 the refresh_token is optional in the response; when absent the
        // client keeps using the one it already has.
        let json = Data("""
        { "access_token": "new-at", "expires_in": 300 }
        """.utf8)

        let credentials = try OIDCTokenResponse.credentials(from: json, now: now, previousRefreshToken: "old-rt")

        XCTAssertEqual(
            credentials,
            .bearer(accessToken: "new-at", refreshToken: "old-rt", expiresAt: now.addingTimeInterval(300))
        )
    }

    func testThrowsWhenAccessTokenMissing() {
        let json = Data(#"{ "refresh_token": "new-rt", "expires_in": 3600 }"#.utf8)

        XCTAssertThrowsError(
            try OIDCTokenResponse.credentials(from: json, now: Date(), previousRefreshToken: "old-rt")
        ) { error in
            XCTAssertEqual(error as? OIDCTokenError, .malformedResponse)
        }
    }

    func testThrowsOnGarbageResponse() {
        let json = Data("not json".utf8)

        XCTAssertThrowsError(
            try OIDCTokenResponse.credentials(from: json, now: Date(), previousRefreshToken: "old-rt")
        ) { error in
            XCTAssertEqual(error as? OIDCTokenError, .malformedResponse)
        }
    }
}
