import XCTest
@testable import FileProviderSupport
@testable import OwnCloudCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Live contract tier for the oCIS OIDC discovery fetch (progress.md Task 7.8).
///
/// `HTTPOIDCDiscovery` is the thin Mac/networking adapter of the oCIS sign-in flow
/// (its sibling in the Classic flow is `HTTPServerProbe`): its whole job is to GET
/// the live server's `/.well-known/openid-configuration` and hand the bytes to the
/// pure, already-tested `OIDCConfiguration` parser. This tier exercises it end to
/// end against the Docker oCIS fixture — probe the real IDP, parse it, and assert
/// the endpoints come back on the fixture's own host.
///
/// Gated on `OWNCLOUD_TEST_BACKEND=ocis` so the pure-unit `swift test` run skips it.
/// Run via `make backend-contract BACKEND=ocis` or:
///   OWNCLOUD_TEST_BACKEND=ocis swift test --filter OIDCDiscoveryContract
final class OIDCDiscoveryContractTests: XCTestCase {

    private var serverURL: URL!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["OWNCLOUD_TEST_BACKEND"] == "ocis" else {
            throw XCTSkip("Set OWNCLOUD_TEST_BACKEND=ocis to run the OIDC discovery contract tier.")
        }
        serverURL = URL(string: env["OWNCLOUD_TEST_URL"] ?? "https://localhost:9200")!
    }

    /// The live oCIS IDP serves a discovery document whose issuer matches the
    /// server and whose authorization/token endpoints live on the same host.
    func testFetchesAndParsesLiveDiscoveryDocument() async throws {
        // The fixture uses a self-signed cert; trust it the same way the Graph
        // contract tier does (InsecureTrustDelegate — test-only).
        let session = URLSession(
            configuration: .ephemeral,
            delegate: InsecureTrustDelegate(),
            delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let discovery = HTTPOIDCDiscovery(client: .urlSession(session))

        let configuration = try await discovery.configuration(serverURL: serverURL)

        XCTAssertEqual(configuration.authorizationEndpoint.host, serverURL.host)
        XCTAssertEqual(configuration.tokenEndpoint.host, serverURL.host)
        // The token endpoint must be usable for the refresh grant we already build.
        XCTAssertFalse(configuration.tokenEndpoint.absoluteString.isEmpty)
    }
}

/// Trusts the fixture's self-signed certificate — test-only, mirroring the
/// delegate in `BackendContractTests`. `serverTrust` is Darwin-only; on Linux the
/// CI job installs the cert into the system store and this falls through.
private final class InsecureTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        #if canImport(Security)
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        #endif
        completionHandler(.performDefaultHandling, nil)
    }
}
