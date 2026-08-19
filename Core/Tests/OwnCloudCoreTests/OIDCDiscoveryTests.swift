import XCTest
@testable import OwnCloudCore

/// Parsing the OIDC discovery document (`/.well-known/openid-configuration`) for
/// the oCIS sign-in flow (Task 7.8). Sign-in and refresh both need the concrete
/// `authorization_endpoint` and `token_endpoint` the server advertises rather than
/// hard-coded paths, so this is the pure decode step the Mac networking layer feeds
/// the fetched bytes into.
final class OIDCDiscoveryTests: XCTestCase {

    func testParsesEndpointsFromDiscoveryDocument() throws {
        let json = Data("""
        {
          "issuer": "https://ocis.test",
          "authorization_endpoint": "https://ocis.test/idp/authorize",
          "token_endpoint": "https://ocis.test/idp/token",
          "scopes_supported": ["openid", "offline_access", "profile"]
        }
        """.utf8)

        let config = try OIDCConfiguration(discoveryJSON: json)

        XCTAssertEqual(config.issuer, URL(string: "https://ocis.test"))
        XCTAssertEqual(config.authorizationEndpoint, URL(string: "https://ocis.test/idp/authorize"))
        XCTAssertEqual(config.tokenEndpoint, URL(string: "https://ocis.test/idp/token"))
    }

    /// `userinfo_endpoint` is optional in RFC 8414 but load-bearing for oCIS: Konnect's
    /// `id_token` carries only `sub`, so the human-facing account name has to come from
    /// UserInfo (OIDC Core §5.3). Parsing must therefore surface it when advertised.
    func testParsesOptionalUserInfoEndpoint() throws {
        let json = Data("""
        {
          "issuer": "https://ocis.test",
          "authorization_endpoint": "https://ocis.test/idp/authorize",
          "token_endpoint": "https://ocis.test/idp/token",
          "userinfo_endpoint": "https://ocis.test/konnect/v1/userinfo"
        }
        """.utf8)

        let config = try OIDCConfiguration(discoveryJSON: json)

        XCTAssertEqual(config.userInfoEndpoint, URL(string: "https://ocis.test/konnect/v1/userinfo"))
    }

    /// A document without `userinfo_endpoint` is still valid — only the two mandatory
    /// endpoints gate parsing, and the caller falls back to the `id_token`'s claims.
    func testAcceptsDocumentWithoutUserInfoEndpoint() throws {
        let json = Data("""
        {
          "issuer": "https://ocis.test",
          "authorization_endpoint": "https://ocis.test/idp/authorize",
          "token_endpoint": "https://ocis.test/idp/token"
        }
        """.utf8)

        XCTAssertNil(try OIDCConfiguration(discoveryJSON: json).userInfoEndpoint)
    }

    func testRejectsDocumentMissingTokenEndpoint() {
        let json = Data("""
        {"issuer":"https://ocis.test","authorization_endpoint":"https://ocis.test/idp/authorize"}
        """.utf8)

        XCTAssertThrowsError(try OIDCConfiguration(discoveryJSON: json)) { error in
            XCTAssertEqual(error as? OIDCConfigurationError, .malformedDiscoveryDocument)
        }
    }

    func testRejectsNonJSON() {
        XCTAssertThrowsError(try OIDCConfiguration(discoveryJSON: Data("<html>nope".utf8))) { error in
            XCTAssertEqual(error as? OIDCConfigurationError, .malformedDiscoveryDocument)
        }
    }
}
