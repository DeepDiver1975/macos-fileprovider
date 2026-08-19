import XCTest
@testable import OwnCloudCore

/// Tasks 4.1–4.5: the backend request construction behind the replicated
/// extension's content operations — hydration (`fetchContents`) and the push
/// handlers (`createItem` / `modifyItem` / `deleteItem`). Every one of them is a
/// WebDAV request on both backends; the builder differs only in its base URL
/// (Classic's files root, or an oCIS space's endpoint). Graph contributes the
/// drive listing and nothing else.
///
/// The `NSFileProviderReplicatedExtension` completion-handler contract and the
/// actual byte streaming to/from disk are the Mac-only adapter; what the core
/// owns and these tests drive is *which HTTP request* each operation becomes and
/// how it routes per backend.
final class RemoteRequestBuilderTests: XCTestCase {

    // MARK: - WebDAV (ownCloud Classic)

    private let davBase = URL(string: "https://cloud.test/remote.php/dav/files/admin")!
    private var dav: WebDAVRequestBuilder { WebDAVRequestBuilder(filesBaseURL: davBase) }

    func testWebDAVFetchIsGetAtItemPath() {
        let req = dav.fetchContents(path: "/Photos/pic.jpg")
        XCTAssertEqual(req.method, .get)
        XCTAssertEqual(req.url, URL(string: "https://cloud.test/remote.php/dav/files/admin/Photos/pic.jpg"))
        XCTAssertFalse(req.hasBody)
    }

    func testWebDAVFetchPercentEncodesPathSegments() {
        let req = dav.fetchContents(path: "/My Report #2.txt")
        XCTAssertEqual(req.url, URL(string: "https://cloud.test/remote.php/dav/files/admin/My%20Report%20%232.txt"))
    }

    func testWebDAVCreateFileIsPutWithBody() {
        let req = dav.createFile(path: "/new.txt")
        XCTAssertEqual(req.method, .put)
        XCTAssertEqual(req.url, URL(string: "https://cloud.test/remote.php/dav/files/admin/new.txt"))
        XCTAssertTrue(req.hasBody)
    }

    func testWebDAVCreateDirectoryIsMkcol() {
        let req = dav.createDirectory(path: "/NewFolder")
        XCTAssertEqual(req.method, .mkcol)
        XCTAssertEqual(req.url, URL(string: "https://cloud.test/remote.php/dav/files/admin/NewFolder"))
        XCTAssertFalse(req.hasBody)
    }

    func testWebDAVModifyIsPutWithIfMatchEtag() {
        let req = dav.modifyContents(path: "/doc.txt", ifMatchETag: "\"v1\"")
        XCTAssertEqual(req.method, .put)
        XCTAssertTrue(req.hasBody)
        // Optimistic concurrency: only overwrite if the server copy still matches.
        XCTAssertEqual(req.headers["If-Match"], "\"v1\"")
    }

    func testWebDAVDeleteIsDelete() {
        let req = dav.delete(path: "/old.txt")
        XCTAssertEqual(req.method, .delete)
        XCTAssertEqual(req.url, URL(string: "https://cloud.test/remote.php/dav/files/admin/old.txt"))
    }

    func testWebDAVMoveIsMoveWithDestinationHeader() {
        let req = dav.move(fromPath: "/a.txt", toPath: "/sub/b.txt")
        XCTAssertEqual(req.method, .move)
        XCTAssertEqual(req.url, URL(string: "https://cloud.test/remote.php/dav/files/admin/a.txt"))
        XCTAssertEqual(req.headers["Destination"], "https://cloud.test/remote.php/dav/files/admin/sub/b.txt")
        XCTAssertEqual(req.headers["Overwrite"], "F")
    }

    // MARK: - Graph (oCIS)
    //
    // Graph's only request is the drive listing (Task 4.5). The file-operation
    // builders that used to be exercised here are gone: their endpoints 404 on
    // oCIS 8.2.0, and all file/folder I/O now runs over each space's WebDAV
    // endpoint — see `SpaceWebDAVEndpointTests` and `BackendConnectionTests`.

    private var graph: GraphRequestBuilder { GraphRequestBuilder(baseURL: URL(string: "https://ocis.test")!) }

    func testGraphListDrivesIsGetOnMeDrives() {
        // Drive-id resolution at sign-in: list the user's drives to find the
        // personal one the domain maps to.
        let req = graph.listDrives()
        XCTAssertEqual(req.method, .get)
        XCTAssertEqual(req.url, URL(string: "https://ocis.test/graph/v1.0/me/drives"))
        XCTAssertFalse(req.hasBody)
    }

    // MARK: - Enumeration requests (Phase 3)

    func testWebDAVEnumerateIsPropfindDepthOne() {
        let req = dav.enumerate(path: "/Photos")
        XCTAssertEqual(req.method, .propfind)
        XCTAssertEqual(req.url, URL(string: "https://cloud.test/remote.php/dav/files/admin/Photos"))
        // Depth:1 lists the immediate children of the container.
        XCTAssertEqual(req.headers["Depth"], "1")
        XCTAssertEqual(req.headers["Content-Type"], "application/xml")
        XCTAssertTrue(req.hasBody)
    }

    func testWebDAVEnumerateBodyRequestsTheParsedProperties() {
        let req = dav.enumerate(path: "/")
        let body = String(data: req.jsonBody ?? Data(), encoding: .utf8) ?? ""
        // The PROPFIND must ask for exactly the props WebDAVMultiStatusParser reads.
        XCTAssertTrue(body.contains("<d:propfind"))
        for prop in ["d:getetag", "d:getcontentlength", "d:getcontenttype", "d:getlastmodified", "d:resourcetype"] {
            XCTAssertTrue(body.contains(prop), "missing \(prop)")
        }
        for prop in ["oc:id", "oc:size", "oc:permissions"] {
            XCTAssertTrue(body.contains(prop), "missing \(prop)")
        }
        XCTAssertTrue(body.contains("xmlns:oc=\"http://owncloud.org/ns\""))
    }

    func testWebDAVPropertiesIsPropfindDepthZeroAtItemPath() {
        // Classic returns no metadata body on PUT/MKCOL, so createItem reads the
        // new item back with a Depth:0 PROPFIND on its own path (just that item,
        // not its children).
        let req = dav.properties(path: "/new.txt")
        XCTAssertEqual(req.method, .propfind)
        XCTAssertEqual(req.url, URL(string: "https://cloud.test/remote.php/dav/files/admin/new.txt"))
        XCTAssertEqual(req.headers["Depth"], "0")
        XCTAssertEqual(req.headers["Content-Type"], "application/xml")
        XCTAssertTrue(req.hasBody)
    }

    func testWebDAVPropertiesBodyRequestsTheParsedProperties() {
        // The read-back must ask for exactly the props WebDAVMultiStatusParser
        // reads — the same body the Depth:1 enumerate PROPFIND uses.
        let req = dav.properties(path: "/new.txt")
        let body = String(data: req.jsonBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("<d:propfind"))
        for prop in ["d:getetag", "d:getcontentlength", "d:getcontenttype", "d:getlastmodified", "d:resourcetype"] {
            XCTAssertTrue(body.contains(prop), "missing \(prop)")
        }
        for prop in ["oc:id", "oc:size", "oc:permissions"] {
            XCTAssertTrue(body.contains(prop), "missing \(prop)")
        }
    }
}
