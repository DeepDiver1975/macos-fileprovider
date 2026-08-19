import XCTest
@testable import OwnCloudCore

/// The OAuth2 client the app signs in as (issue #17). The values are oCIS's own
/// shipped defaults, so these tests pin the two properties the *server* enforces:
/// the redirect URI must match its registration byte for byte (lico compares
/// custom-scheme URIs by string equality), and its scheme must be the one the
/// `ASWebAuthenticationSession` callback watches for.
final class OCISClientRegistrationTests: XCTestCase {

    func testMobileRegistrationMatchesTheRedirectURIOCISShips() {
        let registration = OCISClientRegistration.ownCloudMobile

        // Byte-for-byte the RedirectURIs entry in oCIS's idp defaultconfig.go.
        XCTAssertEqual(registration.redirectURI, "oc://ios.owncloud.com")
        XCTAssertNotNil(registration.clientSecret)
        // offline_access is what makes the IDP issue a refresh token at all; without
        // it the mount dies with the first access token.
        XCTAssertTrue(registration.scope.contains("offline_access"), registration.scope)
        XCTAssertTrue(registration.scope.contains("openid"), registration.scope)
    }

    /// The callback scheme is derived, not typed twice — a hand-written copy could
    /// drift from the redirect URI and the browser sheet would never return.
    func testCallbackSchemeIsDerivedFromTheRedirectURI() {
        XCTAssertEqual(OCISClientRegistration.ownCloudMobile.callbackScheme, "oc")

        let custom = OCISClientRegistration(
            clientID: "c", clientSecret: nil,
            redirectURI: "myapp://oidc", scope: "openid")
        XCTAssertEqual(custom.callbackScheme, "myapp")
    }
}
