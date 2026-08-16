import XCTest
@testable import OwnCloudCore

/// Tasks 4.1–4.4: the backend request construction behind the replicated
/// extension's content operations — hydration (`fetchContents`) and the push
/// handlers (`createItem` / `modifyItem` / `deleteItem`), for both WebDAV
/// (ownCloud Classic) and Graph (oCIS).
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

    private let driveID = "1284d238$4c510ada"
    private var graph: GraphRequestBuilder { GraphRequestBuilder(baseURL: URL(string: "https://ocis.test")!) }

    func testGraphFetchIsGetOnContentEndpoint() {
        let req = graph.fetchContents(driveID: driveID, itemID: "1284d238$4c510ada!file")
        XCTAssertEqual(req.method, .get)
        XCTAssertEqual(
            req.url,
            URL(string: "https://ocis.test/graph/v1.0/drives/1284d238$4c510ada/items/1284d238$4c510ada!file/content")
        )
    }

    func testGraphModifyIsPutOnContentEndpoint() {
        let req = graph.modifyContents(driveID: driveID, itemID: "x!f", ifMatchETag: "\"v2\"")
        XCTAssertEqual(req.method, .put)
        XCTAssertTrue(req.hasBody)
        XCTAssertEqual(req.headers["If-Match"], "\"v2\"")
        XCTAssertEqual(req.url, URL(string: "https://ocis.test/graph/v1.0/drives/1284d238$4c510ada/items/x!f/content"))
    }

    func testGraphDeleteIsDeleteOnItem() {
        let req = graph.delete(driveID: driveID, itemID: "x!f")
        XCTAssertEqual(req.method, .delete)
        XCTAssertEqual(req.url, URL(string: "https://ocis.test/graph/v1.0/drives/1284d238$4c510ada/items/x!f"))
    }

    func testGraphCreateFolderPostsToParentChildren() {
        let req = graph.createFolder(driveID: driveID, parentID: "x!root", name: "New Folder")
        XCTAssertEqual(req.method, .post)
        XCTAssertEqual(req.url, URL(string: "https://ocis.test/graph/v1.0/drives/1284d238$4c510ada/items/x!root/children"))
        XCTAssertTrue(req.hasBody)
        XCTAssertEqual(req.headers["Content-Type"], "application/json")
    }
}
