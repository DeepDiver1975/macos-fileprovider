import XCTest
@testable import FileProviderSupport
@testable import OwnCloudCore

/// Live contract tier for the Classic sign-in probe (progress.md Task 7.11).
///
/// `HTTPServerProbe` is the one Mac/networking adapter in the sign-in flow with no
/// unit test — its whole job is to turn a *live* server's two endpoint responses
/// into the `BackendProbeResult` the tested `SignInResolver` consumes. This tier
/// exercises it end to end against the Docker Classic fixture, the same way
/// `BackendContractTests` exercises the request/parse layer: probe the real server,
/// feed the result through the resolver, and assert the account it produces.
///
/// Gated on `OWNCLOUD_TEST_BACKEND=classic` so the pure-unit `swift test` run skips
/// it. Run it via `make backend-contract BACKEND=classic` (which brings the fixture
/// up, runs the contract filter, and tears down) or:
///   OWNCLOUD_TEST_BACKEND=classic swift test --filter ServerProbeContract
final class ServerProbeContractTests: XCTestCase {

    private var serverURL: URL!
    private var username: String!
    private var password: String!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["OWNCLOUD_TEST_BACKEND"] == "classic" else {
            throw XCTSkip("Set OWNCLOUD_TEST_BACKEND=classic to run the sign-in probe contract tier.")
        }
        serverURL = URL(string: env["OWNCLOUD_TEST_URL"] ?? "http://localhost:8080")!
        username = env["OWNCLOUD_TEST_USER"] ?? "admin"
        password = env["OWNCLOUD_TEST_PASSWORD"] ?? "admin"
    }

    /// The live Classic fixture serves `status.php` (installed) but not the OIDC
    /// discovery document, so the probe must report exactly the Classic signal.
    func testProbeDetectsClassicSignalsFromLiveFixture() async throws {
        let probe = await HTTPServerProbe().probe(serverURL: serverURL)
        XCTAssertFalse(probe.hasOpenIDConfiguration,
                       "Classic does not serve /.well-known/openid-configuration")
        XCTAssertNotNil(probe.classicStatusJSON, "status.php returned a body")
        // The probe result must be enough for the detector to classify it Classic.
        XCTAssertEqual(BackendDetector.detect(from: probe), .classic)
    }

    /// The full sign-in resolution the settings window drives: probe the real
    /// server, run `SignInResolver`, and confirm it yields a Classic Basic account.
    func testResolvesSignInAgainstLiveFixture() async throws {
        let probe = await HTTPServerProbe().probe(serverURL: serverURL)
        let result = SignInResolver.resolve(
            serverURL: serverURL.absoluteString,
            username: username,
            password: password,
            probe: probe)

        let resolved = try result.get()
        XCTAssertEqual(resolved.account.backend, .classic)
        XCTAssertEqual(resolved.account.username, username)
        XCTAssertEqual(resolved.credentials, .basic(username: username, password: password))
        // Classic is a single sync root over its files root — no drive id.
        XCTAssertNil(resolved.syncRoot.driveID)
    }
}
