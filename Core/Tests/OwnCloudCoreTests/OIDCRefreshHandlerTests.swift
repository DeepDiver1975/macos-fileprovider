import XCTest
@testable import OwnCloudCore

/// Task 7.6 / 2.5 remainder: wiring the OIDC token endpoint into a
/// `SessionManager.RefreshHandler`. The handler is the composition already tested
/// piecewise — `OIDCTokenRequestBuilder.refresh` shapes the POST, a transport
/// sends it, `OIDCTokenResponse.credentials` parses the reply. This test pins the
/// composition (and its error mapping) with a fake transport, no network.
final class OIDCRefreshHandlerTests: XCTestCase {

    private let tokenEndpoint = URL(string: "https://ocis.test/idp/token")!

    func testHandlerSendsRefreshGrantAndParsesFreshCredentials() throws {
        var sentRequest: RemoteRequest?
        let handler = OIDCRefreshHandler.make(
            tokenEndpoint: tokenEndpoint,
            clientID: "web",
            scope: "openid offline_access",
            now: { Date(timeIntervalSince1970: 1000) },
            send: { request in
                sentRequest = request
                return Data("""
                {"access_token":"new-at","refresh_token":"new-rt","expires_in":3600}
                """.utf8)
            })

        let credentials = try handler("old-rt")

        // The request is the form-encoded refresh grant to the token endpoint.
        XCTAssertEqual(sentRequest?.method, .post)
        XCTAssertEqual(sentRequest?.url, tokenEndpoint)
        let body = String(data: sentRequest?.jsonBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
        XCTAssertTrue(body.contains("refresh_token=old-rt"))
        XCTAssertTrue(body.contains("client_id=web"))

        // expires_in (3600) is resolved against the injected now (t=1000).
        XCTAssertEqual(credentials, .bearer(
            accessToken: "new-at", refreshToken: "new-rt",
            expiresAt: Date(timeIntervalSince1970: 4600)))
    }

    func testHandlerRetainsPreviousRefreshTokenWhenResponseOmitsIt() throws {
        let handler = OIDCRefreshHandler.make(
            tokenEndpoint: tokenEndpoint, clientID: "web", scope: nil,
            now: { Date(timeIntervalSince1970: 0) },
            send: { _ in Data("""
            {"access_token":"at2","expires_in":100}
            """.utf8) })

        let credentials = try handler("keep-me")
        XCTAssertEqual(credentials, .bearer(
            accessToken: "at2", refreshToken: "keep-me",
            expiresAt: Date(timeIntervalSince1970: 100)))
    }

    func testHandlerThrowsOnMalformedResponse() {
        let handler = OIDCRefreshHandler.make(
            tokenEndpoint: tokenEndpoint, clientID: "web", scope: nil,
            now: { Date(timeIntervalSince1970: 0) },
            send: { _ in Data("nonsense".utf8) })

        XCTAssertThrowsError(try handler("rt")) { error in
            XCTAssertEqual(error as? OIDCTokenError, .malformedResponse)
        }
    }

    func testHandlerPropagatesTransportError() {
        struct Boom: Error {}
        let handler = OIDCRefreshHandler.make(
            tokenEndpoint: tokenEndpoint, clientID: "web", scope: nil,
            now: { Date(timeIntervalSince1970: 0) },
            send: { _ in throw Boom() })

        XCTAssertThrowsError(try handler("rt")) { error in
            XCTAssertTrue(error is Boom)
        }
    }
}
