import XCTest
@testable import OwnCloudCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Backend-contract tier (progress.md AC-2): drive the core's real request
/// shaping, `URLRequestFactory`, `URLSession`, and response parsers against a
/// **live** backend brought up from the Docker fixtures.
///
/// Gated on `OWNCLOUD_TEST_BACKEND` (`classic` | `ocis`) so `swift test` in the
/// pure-unit run skips it. Run it via:
///   OWNCLOUD_TEST_BACKEND=classic swift test --filter BackendContract
///   OWNCLOUD_TEST_BACKEND=ocis    swift test --filter BackendContract
/// These match the CI matrix step and `make acceptance` (AC-4).
final class BackendContractTests: XCTestCase {

    private var backend: Backend!
    private var config: FixtureConfig!

    override func setUpWithError() throws {
        guard let raw = ProcessInfo.processInfo.environment["OWNCLOUD_TEST_BACKEND"],
              let backend = Backend(rawValue: raw) else {
            throw XCTSkip("Set OWNCLOUD_TEST_BACKEND=classic|ocis to run the backend-contract tier.")
        }
        self.backend = backend
        self.config = FixtureConfig.forBackend(backend)
    }

    // MARK: Classic — PROPFIND parses into WebDAVItems

    func testClassicPropfindParsesFilesRoot() throws {
        try XCTSkipUnless(backend == .classic, "Classic-only.")
        let request = RemoteRequest(
            method: .propfind,
            url: config.serverURL.appendingPathComponent("remote.php/dav/files/\(config.username)/"),
            headers: ["Depth": "1"]
        )
        let (data, status) = try send(request)
        XCTAssertEqual(status, 207, "PROPFIND must return 207 Multi-Status")

        let items = try WebDAVMultiStatusParser().parse(data)
        // At least the collection root itself is reported.
        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(items.contains { $0.isDirectory }, "the files root is a collection")
    }

    // MARK: oCIS — Graph drive list parses into GraphDrives

    func testOCISDriveListParses() throws {
        try XCTSkipUnless(backend == .ocis, "oCIS-only.")
        let request = RemoteRequest(
            method: .get,
            url: config.serverURL.appendingPathComponent("graph/v1.0/me/drives")
        )
        let (data, status) = try send(request)
        XCTAssertEqual(status, 200)

        let drives = try GraphJSONDecoder().decodeDriveList(data)
        XCTAssertFalse(drives.isEmpty, "admin has at least a personal drive")
        XCTAssertTrue(drives.contains { $0.driveType == "personal" })
    }

    // MARK: oCIS — the space catalog built through the listDrives() builder

    func testOCISSpaceCatalogFromListDrivesBuilder() throws {
        try XCTSkipUnless(backend == .ocis, "oCIS-only.")
        // Task 7.2: fetch the catalog through the real GraphRequestBuilder.listDrives()
        // request (not a hand-built URL) and map it to a SpaceCatalog.
        let builder = GraphRequestBuilder(baseURL: config.serverURL)
        let (data, status) = try send(builder.listDrives())
        XCTAssertEqual(status, 200)

        let catalog = SpaceCatalog(drives: try GraphJSONDecoder().decodeDriveList(data))
        XCTAssertFalse(catalog.spaces.isEmpty, "admin has at least a personal space")
        XCTAssertTrue(catalog.spaces.contains { $0.driveType == "personal" })
        // A drive the token cannot see never appears — the listing is scoped to the
        // authenticated user's drives, so a fabricated id is absent by construction.
        XCTAssertFalse(catalog.spaces.contains { $0.driveID == "space-the-token-cannot-see" })
    }

    // MARK: Shared transport

    /// Issue `remote` synchronously with Basic auth, returning body + status.
    private func send(_ remote: RemoteRequest) throws -> (Data, Int) {
        let auth = "Basic " + Data("\(config.username):\(config.password)".utf8).base64EncodedString()
        let urlRequest = try URLRequestFactory.urlRequest(from: remote, authorization: auth)

        let session = URLSession(
            configuration: .ephemeral,
            delegate: InsecureTrustDelegate(),   // fixtures use a self-signed cert
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        var result: Result<(Data, Int), Error>?
        let done = expectation(description: "request")
        let task = session.dataTask(with: urlRequest) { data, response, error in
            if let error { result = .failure(error) }
            else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                result = .success((data ?? Data(), status))
            }
            done.fulfill()
        }
        task.resume()
        wait(for: [done], timeout: 30)

        switch result {
        case let .success(pair): return pair
        case let .failure(error): throw error
        case .none: throw XCTSkip("no response")
        }
    }
}

/// Fixture connection settings, matching test/fixtures/*/docker-compose.yml.
private struct FixtureConfig {
    let serverURL: URL
    let username: String
    let password: String

    static func forBackend(_ backend: Backend) -> FixtureConfig {
        // Overridable so CI / `make acceptance` can point at a remote fixture.
        let env = ProcessInfo.processInfo.environment
        switch backend {
        case .classic:
            return FixtureConfig(
                serverURL: URL(string: env["OWNCLOUD_TEST_URL"] ?? "http://localhost:8080")!,
                username: env["OWNCLOUD_TEST_USER"] ?? "admin",
                password: env["OWNCLOUD_TEST_PASSWORD"] ?? "admin"
            )
        case .ocis:
            return FixtureConfig(
                serverURL: URL(string: env["OWNCLOUD_TEST_URL"] ?? "https://localhost:9200")!,
                username: env["OWNCLOUD_TEST_USER"] ?? "admin",
                password: env["OWNCLOUD_TEST_PASSWORD"] ?? "admin"
            )
        }
    }
}

/// Trusts the fixture's self-signed certificate. Test-only — the production
/// networking layer pins/validates the real certificate (progress.md Task 6.2).
///
/// `serverTrust` and `URLCredential(trust:)` are Darwin-only; swift-corelibs-
/// foundation on Linux marks them unavailable, so the trust override is compiled
/// only where the Security framework exists. On Linux the fixture cert is trusted
/// through the system CA store instead (the CI ocis job installs it), and the
/// delegate falls through to default handling.
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
