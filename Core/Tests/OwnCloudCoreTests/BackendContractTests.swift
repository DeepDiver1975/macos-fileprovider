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

    // MARK: oCIS — every space reports the WebDAV endpoint file I/O runs over

    func testOCISPersonalDriveReportsAWebDavURL() throws {
        try XCTSkipUnless(backend == .ocis, "oCIS-only.")
        // Task 4.5: `root.webDavUrl` is the whole reason Graph is still called. If a
        // server stopped reporting it there would be nothing to address items under,
        // so this is the contract the space-WebDAV routing rests on.
        let builder = GraphRequestBuilder(baseURL: config.serverURL)
        let (data, status) = try send(builder.listDrives())
        XCTAssertEqual(status, 200)

        let drives = try GraphJSONDecoder().decodeDriveList(data)
        let personal = try XCTUnwrap(GraphDrive.personalDrive(in: drives))
        let webDavUrl = try XCTUnwrap(personal.root?.webDavUrl, "the personal drive must report root.webDavUrl")
        XCTAssertFalse(webDavUrl.isEmpty)
        // The reported URL is the *per-space* one; the requests this code sends are
        // rooted at its parent collection, because an oc:id is addressed as
        // `/dav/spaces/{oc:id}` — a sibling of the drive id, not a child of it.
        XCTAssertTrue(webDavUrl.hasSuffix("/" + personal.id), "expected the drive id to be the last segment of \(webDavUrl)")
        XCTAssertEqual(
            SpaceWebDAVEndpoint.baseURL(
                serverURL: config.serverURL, driveID: personal.id, reportedWebDavURL: webDavUrl
            ).absoluteString,
            SpaceWebDAVEndpoint.baseURL(serverURL: config.serverURL, driveID: personal.id).absoluteString,
            "the derivation and the server-reported URL must agree on the collection"
        )
    }

    // MARK: oCIS — PROPFIND Depth:1 on a space parses, and every child carries oc:id

    func testOCISSpaceRootEnumerationYieldsIdentifiedChildren() async throws {
        try XCTSkipUnless(backend == .ocis, "oCIS-only.")
        let (connection, driveID) = try await ocisConnection()
        // Ensure there is at least one child to assert about, whatever state the
        // fixture is in.
        let probe = "contract-probe-enumerate"
        try await removeIfPresent(named: probe, connection: connection)
        _ = try await client().send(
            connection.createItemRequest(parentID: .rootContainer, name: probe, isDirectory: true),
            authorization: auth)
        try await addAsyncTeardown { try await self.removeIfPresent(named: probe, connection: connection) }

        let result = try await enumerateAll(from: connection.enumerationSource(for: .rootContainer))

        XCTAssertFalse(result.items.isEmpty, "the space root lists its children")
        // The Depth:1 self entry must not be reported — it would be a second
        // identifier for the container being listed.
        XCTAssertFalse(result.items.contains { $0.identifier == .rootContainer })
        for item in result.items {
            // Identifiers are oc:ids, and every oc:id in a space begins with the
            // drive id. An item without one would have fallen back to a path
            // identifier, which cannot be addressed under /dav/spaces.
            XCTAssertTrue(
                item.identifier.rawValue.hasPrefix(driveID + "!"),
                "child \(item.filename) has identifier \(item.identifier.rawValue), not an oc:id")
            XCTAssertFalse(item.filename.isEmpty)
        }
        XCTAssertTrue(result.items.contains { $0.filename == probe && $0.isDirectory })
    }

    // MARK: oCIS — a top-level child's oc:file-parent normalises to the root container

    func testOCISTopLevelChildIsParentedToTheRootContainer() async throws {
        try XCTSkipUnless(backend == .ocis, "oCIS-only.")
        // The root's own oc:id is the `!`-suffixed form of the drive id, which is a
        // derivation this code relies on (`SpaceWebDAVEndpoint.isRoot`). If a server
        // ever reported a different root id, a top-level child would be parented to a
        // container the system has never heard of — this test is that alarm.
        let (connection, _) = try await ocisConnection()
        let probe = "contract-probe-parent.txt"
        try await removeIfPresent(named: probe, connection: connection)
        _ = try await client().send(
            connection.createItemRequest(parentID: .rootContainer, name: probe, isDirectory: false),
            body: Data("parent probe\n".utf8), authorization: auth)
        try await addAsyncTeardown { try await self.removeIfPresent(named: probe, connection: connection) }

        let body = try await client().send(
            connection.readBackNewItemRequest(parentID: .rootContainer, name: probe), authorization: auth)
        let description = try XCTUnwrap(try connection.readBackItem(fromOCISPropfind: body))

        XCTAssertEqual(description.parentIdentifier, .rootContainer)
        XCTAssertEqual(description.filename, probe)
    }

    // MARK: oCIS — full round trip through BackendConnection, fileid stable across MOVE

    func testOCISRoundTripKeepsTheFileIDAcrossAMove() async throws {
        try XCTSkipUnless(backend == .ocis, "oCIS-only.")
        // MKCOL → PUT → PROPFIND → MOVE → GET → DELETE, entirely through the seam the
        // extension calls. The decisive assertion is that the oc:id is unchanged after
        // the MOVE: stable ids are what let oCIS identifiers be ids rather than paths
        // (Classic's must be paths, which is why its identifiers go stale on rename).
        let (connection, _) = try await ocisConnection()
        let folder = "contract-probe-roundtrip"
        let file = "note.txt"
        let renamed = "renamed.txt"
        let remote = client()

        try await removeIfPresent(named: folder, connection: connection)
        try await addAsyncTeardown { try await self.removeIfPresent(named: folder, connection: connection) }

        // MKCOL the folder, then read it back to learn its server-assigned oc:id.
        _ = try await remote.send(
            connection.createItemRequest(parentID: .rootContainer, name: folder, isDirectory: true),
            authorization: auth)
        let folderBody = try await remote.send(
            connection.readBackNewItemRequest(parentID: .rootContainer, name: folder), authorization: auth)
        let folderDescription = try XCTUnwrap(try connection.readBackItem(fromOCISPropfind: folderBody))
        XCTAssertTrue(folderDescription.isDirectory)

        // PUT the file at the top level, then read it back by name.
        let contents = Data("round trip\n".utf8)
        _ = try await remote.send(
            connection.createItemRequest(parentID: .rootContainer, name: file, isDirectory: false),
            body: contents, authorization: auth)
        let createdBody = try await remote.send(
            connection.readBackNewItemRequest(parentID: .rootContainer, name: file), authorization: auth)
        let created = try XCTUnwrap(try connection.readBackItem(fromOCISPropfind: createdBody))
        let fileID = created.identifier
        XCTAssertEqual(created.filename, file)
        XCTAssertEqual(created.size, contents.count)

        // MOVE it into the folder under a new name — a rename and a reparent at once.
        _ = try await remote.send(
            connection.moveRequest(
                itemID: fileID.rawValue, newName: renamed, newParentID: folderDescription.identifier.rawValue),
            authorization: auth)

        // The id must still address the item, and now report the new name and parent.
        let movedBody = try await remote.send(
            connection.itemMetadataRequest(itemID: fileID.rawValue), authorization: auth)
        let moved = try XCTUnwrap(try connection.readBackItem(fromOCISPropfind: movedBody))
        XCTAssertEqual(moved.identifier, fileID, "the oc:id must survive rename and reparent")
        XCTAssertEqual(moved.filename, renamed)
        XCTAssertEqual(moved.parentIdentifier, folderDescription.identifier)

        // GET by the unchanged id returns the bytes that were written.
        let fetched = try await remote.send(
            connection.fetchContentsRequest(itemID: fileID.rawValue), authorization: auth)
        XCTAssertEqual(fetched, contents)

        // DELETE by id, and the id stops resolving.
        _ = try await remote.send(connection.deleteRequest(itemID: fileID.rawValue), authorization: auth)
        do {
            _ = try await remote.send(connection.itemMetadataRequest(itemID: fileID.rawValue), authorization: auth)
            XCTFail("a deleted item must not still resolve by its oc:id")
        } catch let error as RemoteError {
            XCTAssertEqual(error, .noSuchItem)
        }
    }

    // MARK: oCIS helpers

    /// A ``BackendConnection`` for the fixture's personal space, with the drive id
    /// resolved the way the extension resolves it — through `me/drives`.
    private func ocisConnection() async throws -> (BackendConnection, driveID: String) {
        let remote = client()
        let builder = GraphRequestBuilder(baseURL: config.serverURL)
        let drives = try GraphJSONDecoder().decodeDriveList(
            try await remote.send(builder.listDrives(), authorization: auth))
        let driveID = try XCTUnwrap(GraphDrive.personalDrive(in: drives)?.id)
        let connection = BackendConnection(
            account: AccountDescriptor(backend: .ocis, serverURL: config.serverURL, username: config.username),
            client: remote,
            authorization: auth,
            driveID: driveID
        )
        return (connection, driveID)
    }

    /// Delete a top-level item by name if it exists, so a probe left behind by an
    /// interrupted run does not fail the next one. A 404 means there was nothing to
    /// clean up; any other failure is real and propagates.
    private func removeIfPresent(named name: String, connection: BackendConnection) async throws {
        let remote = client()
        do {
            let body = try await remote.send(
                connection.readBackNewItemRequest(parentID: .rootContainer, name: name), authorization: auth)
            guard let existing = try connection.readBackItem(fromOCISPropfind: body) else { return }
            _ = try await remote.send(
                connection.deleteRequest(itemID: existing.identifier.rawValue), authorization: auth)
        } catch RemoteError.noSuchItem {
            return
        }
    }

    /// `addTeardownBlock`'s async overload, wrapped so the call reads the same as the
    /// synchronous one at the point of use.
    private func addAsyncTeardown(_ block: @escaping @Sendable () async throws -> Void) async throws {
        addTeardownBlock { try await block() }
    }

    // MARK: Shared transport

    /// Basic-auth header for the fixture account.
    private var auth: String {
        "Basic " + Data("\(config.username):\(config.password)".utf8).base64EncodedString()
    }

    /// A production ``RemoteClient`` over a session that trusts the fixture's
    /// self-signed cert — the same request shaping and status classification the
    /// extension uses, so these tests exercise `RemoteError` mapping too.
    private func client() -> RemoteClient {
        let session = URLSession(
            configuration: .ephemeral,
            delegate: InsecureTrustDelegate(),
            delegateQueue: nil
        )
        return RemoteClient { urlRequest in
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, http)
        }
    }

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
