import XCTest
@testable import OwnCloudCore

/// Task 7.11 + issue #17: the headless half of the sign-in flow, in two steps that
/// mirror what the sheet can actually know when.
///
/// `SignInResolver.route` answers "which sign-in does this server call for?" from the
/// server field and a `BackendProbeResult` (from the Mac-only `HTTPServerProbe`)
/// **alone** — because at that point nothing else has been typed: an oCIS sign-in
/// never has a username, and a Classic one has not been asked for it yet.
/// `resolveClassic` is the second step, turning the credentials the Classic branch
/// then collects into an account + credential + sync root. The HTTP probing and the
/// SwiftUI sheet are Mac-gated; every *decision* lives here so it is covered by the
/// Linux-buildable suite.
final class SignInResolverTests: XCTestCase {

    /// A probe result standing in for a live ownCloud Classic server.
    private func classicProbe() -> BackendProbeResult {
        let status = #"{"installed":true,"maintenance":false,"version":"10.15.0.0","productname":"ownCloud"}"#
        return BackendProbeResult(hasOpenIDConfiguration: false, classicStatusJSON: Data(status.utf8))
    }

    private func ocisProbe() -> BackendProbeResult {
        BackendProbeResult(hasOpenIDConfiguration: true, classicStatusJSON: nil)
    }

    // MARK: - Step 1: routing, from the server alone

    func testEmptyServerURLIsRejected() {
        XCTAssertEqual(SignInResolver.route(serverURL: "   ", probe: classicProbe()),
                       .failure(.emptyServerURL))
    }

    func testUnparseableServerURLIsRejected() {
        // A string with no host cannot address a server.
        XCTAssertEqual(SignInResolver.route(serverURL: "http://", probe: classicProbe()),
                       .failure(.invalidServerURL))
    }

    func testNeitherSignalDetectedIsRejected() {
        // No OIDC and no valid status.php — not an ownCloud server we can use.
        let probe = BackendProbeResult(hasOpenIDConfiguration: false, classicStatusJSON: nil)
        XCTAssertEqual(SignInResolver.route(serverURL: "http://example.test", probe: probe),
                       .failure(.backendNotDetected))
    }

    /// A Classic server routes to the credentials step. Crucially this happens with no
    /// username typed — the sheet has not asked for one yet, so demanding it here
    /// would dead-end the very first step.
    func testClassicProbeRoutesToTheCredentialsStep() {
        XCTAssertEqual(SignInResolver.route(serverURL: "http://localhost:8080", probe: classicProbe()),
                       .success(.classic(serverURL: URL(string: "http://localhost:8080")!)))
    }

    /// Issue #17: an oCIS server routes to the OIDC flow. It used to be rejected with
    /// `ocisNotSupportedYet`, which is what made Infinite Scale unreachable from the
    /// settings UI.
    func testOCISProbeRoutesToTheOIDCFlow() {
        XCTAssertEqual(SignInResolver.route(serverURL: "https://ocis.test", probe: ocisProbe()),
                       .success(.oidc(serverURL: URL(string: "https://ocis.test")!)))
    }

    func testSchemelessServerGetsHTTPPrepended() {
        // For fixture ergonomics a bare host is treated as plain HTTP.
        XCTAssertEqual(SignInResolver.route(serverURL: "localhost:8080", probe: classicProbe()),
                       .success(.classic(serverURL: URL(string: "http://localhost:8080")!)))
    }

    /// The server field is probed before it is routed, so the normalization the probe
    /// saw and the URL the OIDC flow uses must be the same one.
    func testOCISRouteNormalizesTheServerURLToo() {
        XCTAssertEqual(SignInResolver.route(serverURL: "  ocis.test  ", probe: ocisProbe()),
                       .success(.oidc(serverURL: URL(string: "http://ocis.test")!)))
    }

    // MARK: - Step 2: resolving the Classic credentials

    func testClassicResolutionYieldsBasicCredentialAndNilDriveSyncRoot() throws {
        let resolved = try SignInResolver.resolveClassic(
            serverURL: URL(string: "http://localhost:8080")!,
            username: "admin", password: "s3cret").get()

        XCTAssertEqual(resolved.account.backend, .classic)
        XCTAssertEqual(resolved.account.serverURL, URL(string: "http://localhost:8080"))
        XCTAssertEqual(resolved.account.username, "admin")
        XCTAssertEqual(resolved.account.displayName, "admin@localhost")
        XCTAssertEqual(resolved.credentials, .basic(username: "admin", password: "s3cret"))
        // Classic is a single sync root over its files root — no drive id.
        XCTAssertNil(resolved.syncRoot.driveID)
        XCTAssertEqual(resolved.syncRoot.account, resolved.account)
    }

    /// The username *is* required once the Classic step is asking for it — it is the
    /// Basic-auth identity, so an empty one cannot be sent.
    func testClassicResolutionRejectsAnEmptyUsername() {
        XCTAssertEqual(
            SignInResolver.resolveClassic(
                serverURL: URL(string: "http://localhost:8080")!, username: "  ", password: "admin"),
            .failure(.emptyUsername))
    }

    /// Whitespace around the typed username is trimmed, so it matches the identity the
    /// Keychain item is keyed by.
    func testClassicResolutionTrimsTheUsername() throws {
        let resolved = try SignInResolver.resolveClassic(
            serverURL: URL(string: "http://localhost:8080")!,
            username: "  admin  ", password: "admin").get()
        XCTAssertEqual(resolved.account.username, "admin")
    }
}
