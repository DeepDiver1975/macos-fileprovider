import XCTest
@testable import OwnCloudCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Live contract tier for the Classic fixture-state action bodies (Task 6.3): drives
/// `ClassicBackendAdmin` against the real Docker fixture and verifies each server-side
/// operation actually landed (via a direct WebDAV read-back). This is the automatable
/// half of the acceptance harness — the fixture provisioning the Given/When steps do —
/// proven end to end, distinct from the Mac/Finder half that needs a signed host.
///
/// Gated on `OWNCLOUD_TEST_BACKEND=classic` like `BackendContractTests`, so a plain
/// `swift test` self-skips and it runs on the classic CI leg:
///   OWNCLOUD_TEST_BACKEND=classic swift test --filter ClassicBackendAdminContract
final class ClassicBackendAdminContractTests: XCTestCase {

    private var filesBaseURL: URL!
    private var auth: String!
    private var session: URLSession!

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["OWNCLOUD_TEST_BACKEND"] == "classic" else {
            throw XCTSkip("Set OWNCLOUD_TEST_BACKEND=classic to run the Classic backend-admin contract tier.")
        }
        let env = ProcessInfo.processInfo.environment
        let serverURL = URL(string: env["OWNCLOUD_TEST_URL"] ?? "http://localhost:8080")!
        let user = env["OWNCLOUD_TEST_USER"] ?? "admin"
        let password = env["OWNCLOUD_TEST_PASSWORD"] ?? "admin"
        filesBaseURL = serverURL.appendingPathComponent("remote.php/dav/files/\(user)")
        auth = "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
        session = URLSession(configuration: .ephemeral, delegate: InsecureTrustContractDelegate(), delegateQueue: nil)
    }

    override func tearDownWithError() throws {
        session?.finishTasksAndInvalidate()
    }

    /// Create a file through the admin, then confirm it exists server-side with the
    /// exact bytes; delete it through the admin, then confirm it is gone.
    func testCreateAndDeleteFileRoundTripLive() async throws {
        let admin = makeAdmin()
        let name = "admin-contract-\(Self.runToken).txt"
        let contents = Data("provisioned by ClassicBackendAdmin\n".utf8)

        try await admin.createFile(path: name, contents: contents)
        let (afterCreate, bodyAfterCreate) = try await rawGET(name)
        XCTAssertEqual(afterCreate, 200, "file should exist after createFile")
        XCTAssertEqual(bodyAfterCreate, contents, "server bytes must match what was provisioned")

        try await admin.deleteFile(path: name)
        let (afterDelete, _) = try await rawGET(name)
        XCTAssertEqual(afterDelete, 404, "file should be gone after deleteFile")
    }

    /// Create a folder with N files through the admin, then confirm the folder lists
    /// exactly N children server-side.
    func testCreateFolderWithNFilesLive() async throws {
        let admin = makeAdmin()
        let folder = "AdminBig-\(Self.runToken)"
        let count = 5

        try await admin.createFolder(path: folder, fileCount: count)
        let children = try await propfindChildCount(folder)
        XCTAssertEqual(children, count, "the folder should contain exactly \(count) provisioned files")

        // Clean up so reruns start fresh.
        try await admin.deleteFile(path: folder)
    }

    // MARK: - Helpers

    /// A per-run token so parallel/repeated runs don't collide on fixture paths.
    /// `Date`/`Math.random` are unavailable in the workflow sandbox but this is a
    /// plain XCTest, so a process-unique value is fine.
    private static let runToken = ProcessInfo.processInfo.globallyUniqueString.prefix(8)

    private func makeAdmin() -> ClassicBackendAdmin {
        // Live URLSession-backed client, trusting the fixture's self-signed cert.
        let session = self.session!
        let client = RemoteClient { req in
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, http)
        }
        return ClassicBackendAdmin(filesBaseURL: filesBaseURL, client: client, authorization: auth)
    }

    /// A raw authenticated GET, returning (status, body) without throwing on non-2xx.
    private func rawGET(_ path: String) async throws -> (Int, Data) {
        var req = URLRequest(url: filesBaseURL.appendingPathComponent(path))
        req.httpMethod = "GET"
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
    }

    /// Count immediate children of `folder` via a Depth:1 PROPFIND (excluding the
    /// folder's own self-entry).
    private func propfindChildCount(_ folder: String) async throws -> Int {
        var req = URLRequest(url: filesBaseURL.appendingPathComponent(folder + "/"))
        req.httpMethod = "PROPFIND"
        req.setValue("1", forHTTPHeaderField: "Depth")
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        let (data, _) = try await session.data(for: req)
        let body = String(data: data, encoding: .utf8) ?? ""
        // Each entry is a <d:response>; subtract 1 for the folder's own self-entry.
        let responses = body.components(separatedBy: "<d:response>").count - 1
        return max(responses - 1, 0)
    }
}

/// Trusts the fixture's self-signed certificate (test-only). Mirrors the delegate in
/// `BackendContractTests`; a separate name avoids a symbol clash across test files.
private final class InsecureTrustContractDelegate: NSObject, URLSessionDelegate {
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
