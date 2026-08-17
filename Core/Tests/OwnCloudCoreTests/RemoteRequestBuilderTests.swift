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

    func testGraphUploadNewFilePutsToParentPathContent() {
        // A new file is uploaded by name under its parent via the `:/name:/content`
        // path syntax; the response is the created driveItem the extension decodes.
        let req = graph.uploadNewFile(driveID: driveID, parentID: "x!root", name: "new file.txt")
        XCTAssertEqual(req.method, .put)
        XCTAssertEqual(req.url, URL(string: "https://ocis.test/graph/v1.0/drives/1284d238$4c510ada/items/x!root:/new%20file.txt:/content"))
        XCTAssertTrue(req.hasBody)
    }

    func testGraphUploadNewFileUnderRootUsesRootSegment() {
        // With no parent id the file lands in the drive root, addressed by the
        // `root:/name:/content` syntax rather than `items/{id}`.
        let req = graph.uploadNewFileUnderRoot(driveID: driveID, name: "note.txt")
        XCTAssertEqual(req.method, .put)
        XCTAssertEqual(req.url, URL(string: "https://ocis.test/graph/v1.0/drives/1284d238$4c510ada/root:/note.txt:/content"))
        XCTAssertTrue(req.hasBody)
    }

    func testGraphCreateFolderUnderRootPostsToRootChildren() {
        let req = graph.createFolderUnderRoot(driveID: driveID, name: "New Folder")
        XCTAssertEqual(req.method, .post)
        XCTAssertEqual(req.url, URL(string: "https://ocis.test/graph/v1.0/drives/1284d238$4c510ada/root/children"))
        XCTAssertTrue(req.hasBody)
    }

    func testGraphMoveIsPatchWithNameAndParentReference() throws {
        // Graph rename/move is a PATCH on the item carrying the new name and/or a
        // new parentReference.id — the ID-addressed counterpart of WebDAV MOVE.
        let req = graph.move(driveID: driveID, itemID: "x!f", newName: "renamed.txt", newParentID: "y!parent")
        XCTAssertEqual(req.method, .patch)
        XCTAssertEqual(req.url, URL(string: "https://ocis.test/graph/v1.0/drives/1284d238$4c510ada/items/x!f"))
        XCTAssertEqual(req.headers["Content-Type"], "application/json")
        XCTAssertTrue(req.hasBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: req.jsonBody ?? Data()) as? [String: Any])
        XCTAssertEqual(json["name"] as? String, "renamed.txt")
        let parentRef = try XCTUnwrap(json["parentReference"] as? [String: Any])
        XCTAssertEqual(parentRef["id"] as? String, "y!parent")
    }

    func testGraphMoveOmitsParentReferenceForPureRename() throws {
        // A rename in place carries only the name, no parentReference.
        let req = graph.move(driveID: driveID, itemID: "x!f", newName: "renamed.txt", newParentID: nil)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: req.jsonBody ?? Data()) as? [String: Any])
        XCTAssertEqual(json["name"] as? String, "renamed.txt")
        XCTAssertNil(json["parentReference"])
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

    func testGraphEnumerateFirstPageIsGetOnRootChildren() {
        let req = graph.enumerate(driveID: driveID, cursor: nil)
        XCTAssertEqual(req.method, .get)
        XCTAssertEqual(req.url, URL(string: "https://ocis.test/graph/v1.0/drives/1284d238$4c510ada/root/children"))
        XCTAssertFalse(req.hasBody)
    }

    func testGraphEnumerateWithCursorFollowsThePageToken() {
        let req = graph.enumerate(driveID: driveID, cursor: PageCursor(rawValue: "abc123"))
        XCTAssertEqual(req.method, .get)
        // The cursor is the opaque $token carried by nextLink/deltaLink.
        XCTAssertEqual(
            req.url,
            URL(string: "https://ocis.test/graph/v1.0/drives/1284d238$4c510ada/root/delta?$token=abc123")
        )
    }
}
