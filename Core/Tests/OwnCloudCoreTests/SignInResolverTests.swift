import XCTest
@testable import OwnCloudCore

/// Task 7.11: the headless half of the Classic sign-in flow. `SignInResolver`
/// turns the raw sign-in fields plus a `BackendProbeResult` (from the Mac-only
/// `HTTPServerProbe`) into either a resolved account+credential+sync-root or a
/// typed error the settings window renders. The HTTP probing and the SwiftUI
/// sheet are Mac-gated; every *decision* — validation, backend choice, credential
/// kind, sync-root shape — lives here so it is covered by the Linux-buildable
/// suite.
final class SignInResolverTests: XCTestCase {

    /// A probe result standing in for a live ownCloud Classic server.
    private func classicProbe() -> BackendProbeResult {
        let status = #"{"installed":true,"maintenance":false,"version":"10.15.0.0","productname":"ownCloud"}"#
        return BackendProbeResult(hasOpenIDConfiguration: false, classicStatusJSON: Data(status.utf8))
    }

    func testEmptyServerURLIsRejected() {
        let result = SignInResolver.resolve(
            serverURL: "   ", username: "admin", password: "admin", probe: classicProbe())
        XCTAssertEqual(result, .failure(.emptyServerURL))
    }

    func testEmptyUsernameIsRejected() {
        let result = SignInResolver.resolve(
            serverURL: "http://localhost:8080", username: "  ", password: "admin", probe: classicProbe())
        XCTAssertEqual(result, .failure(.emptyUsername))
    }

    func testUnparseableServerURLIsRejected() {
        // A string with no host cannot address a server.
        let result = SignInResolver.resolve(
            serverURL: "http://", username: "admin", password: "admin", probe: classicProbe())
        XCTAssertEqual(result, .failure(.invalidServerURL))
    }

    func testClassicProbeResolvesBasicCredentialAndNilDriveSyncRoot() throws {
        let result = SignInResolver.resolve(
            serverURL: "http://localhost:8080", username: "admin", password: "s3cret", probe: classicProbe())
        let resolved = try result.get()
        XCTAssertEqual(resolved.account.backend, .classic)
        XCTAssertEqual(resolved.account.serverURL, URL(string: "http://localhost:8080"))
        XCTAssertEqual(resolved.account.username, "admin")
        XCTAssertEqual(resolved.account.displayName, "admin@localhost")
        XCTAssertEqual(resolved.credentials, .basic(username: "admin", password: "s3cret"))
        // Classic is a single sync root over its files root — no drive id.
        XCTAssertNil(resolved.syncRoot.driveID)
        XCTAssertEqual(resolved.syncRoot.account, resolved.account)
    }

    func testOCISProbeIsRejectedInClassicOnlyScope() {
        // oCIS needs OIDC, which this flow does not implement yet — reject with a
        // specific error so the UI can say so rather than silently failing.
        let probe = BackendProbeResult(hasOpenIDConfiguration: true, classicStatusJSON: nil)
        let result = SignInResolver.resolve(
            serverURL: "https://ocis.test", username: "einstein", password: "relativity", probe: probe)
        XCTAssertEqual(result, .failure(.ocisNotSupportedYet))
    }

    func testNeitherSignalDetectedIsRejected() {
        // No OIDC and no valid status.php — not an ownCloud server we can use.
        let probe = BackendProbeResult(hasOpenIDConfiguration: false, classicStatusJSON: nil)
        let result = SignInResolver.resolve(
            serverURL: "http://example.test", username: "admin", password: "admin", probe: probe)
        XCTAssertEqual(result, .failure(.backendNotDetected))
    }

    func testSchemelessServerGetsHTTPPrepended() throws {
        // For fixture ergonomics a bare host is treated as plain HTTP.
        let result = SignInResolver.resolve(
            serverURL: "localhost:8080", username: "admin", password: "admin", probe: classicProbe())
        let resolved = try result.get()
        XCTAssertEqual(resolved.account.serverURL, URL(string: "http://localhost:8080"))
    }
}
