import XCTest
@testable import OwnCloudCore

/// Task 7.9: the UI extension is a *launcher*. On `prepare(forError:)` it opens the
/// containing app at the failing account's sign-in via a custom URL scheme — no
/// second OIDC implementation inside the sandboxed appex. The URL it builds and the
/// app's parse of it are pure logic, tested here; the AppKit `open(_:)` call and the
/// `FPUIActionExtensionViewController` sheet are the Mac-only shell over this.
final class AppLaunchURLTests: XCTestCase {

    private let einstein = AccountDescriptor(
        backend: .ocis, serverURL: URL(string: "https://ocis.test")!, username: "einstein")

    func testReconnectURLRoundTripsTheAccountIdentifier() {
        let url = AppLaunchURL.reconnectURL(accountIdentifier: einstein.accountIdentifier)

        XCTAssertEqual(url.scheme, AppLaunchURL.scheme)
        // The appex hands the identifier off; the app resolves it back to the account.
        let parsed = AppLaunchURL.parse(url)
        XCTAssertEqual(parsed, .reconnect(accountIdentifier: einstein.accountIdentifier))
    }

    func testReconnectURLSurvivesAnIdentifierWithReservedCharacters() {
        // accountIdentifier is "backend|encodedURL|encodedUsername" — the "|" and "%"
        // must survive being put through a query item and read back.
        let account = AccountDescriptor(
            backend: .classic, serverURL: URL(string: "http://localhost:8080")!, username: "a|b")
        let url = AppLaunchURL.reconnectURL(accountIdentifier: account.accountIdentifier)
        XCTAssertEqual(AppLaunchURL.parse(url), .reconnect(accountIdentifier: account.accountIdentifier))
    }

    func testParseRejectsAForeignScheme() {
        XCTAssertNil(AppLaunchURL.parse(URL(string: "https://ocis.test/reconnect?account=x")!))
    }

    func testParseRejectsAnUnknownAction() {
        let url = URL(string: "\(AppLaunchURL.scheme)://frobnicate?account=x")!
        XCTAssertNil(AppLaunchURL.parse(url))
    }

    func testParseRejectsReconnectWithNoAccount() {
        let url = URL(string: "\(AppLaunchURL.scheme)://reconnect")!
        XCTAssertNil(AppLaunchURL.parse(url))
    }
}
