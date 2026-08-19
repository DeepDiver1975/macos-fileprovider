import XCTest
@testable import OwnCloudCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The composition root that assembles a backend's enumeration source, content
/// downloader, and uploader from an ``AccountDescriptor`` (progress.md Phase 3–5).
/// It encodes the one difference the two backends force on the provider: ownCloud
/// Classic is **path-addressed** (WebDAV under `remote.php/dav/files/{user}`) while
/// oCIS is **ID-addressed** (Graph under `drives/{driveID}`). The extension holds
/// one of these per domain and asks it for the pieces each handler needs.
///
/// Driven with an injected `RemoteClient` performer, so no live server is needed.
final class BackendConnectionTests: XCTestCase {

    private func client(status: Int, body: Data, capture: ((URLRequest) -> Void)? = nil) -> RemoteClient {
        RemoteClient { urlRequest in
            capture?(urlRequest)
            return (body, HTTPURLResponse(url: urlRequest.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    // MARK: WebDAV (Classic) — path-addressed

    func testClassicRootEnumerationTargetsTheUsersFilesRoot() async throws {
        var seen: URLRequest?
        let account = AccountDescriptor(backend: .classic, serverURL: URL(string: "https://cloud.test")!, username: "admin")
        let body = Data("""
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
          <d:response><d:href>/remote.php/dav/files/admin/</d:href>
            <d:propstat><d:prop><oc:id>root</oc:id><d:resourcetype><d:collection/></d:resourcetype></d:prop>
            <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
          <d:response><d:href>/remote.php/dav/files/admin/readme.txt</d:href>
            <d:propstat><d:prop><oc:id>id-1</oc:id><d:resourcetype/><d:getetag>"e"</d:getetag></d:prop>
            <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        </d:multistatus>
        """.utf8)
        let connection = BackendConnection(account: account, client: client(status: 207, body: body, capture: { seen = $0 }), authorization: "Basic abc")

        let source = connection.enumerationSource(for: .rootContainer)
        let page = try await source.fetchPage(cursor: nil)

        // Hits the per-user WebDAV files root (trailing slash: it's a collection)
        // and drops the self-entry.
        XCTAssertEqual(seen?.url?.absoluteString, "https://cloud.test/remote.php/dav/files/admin/")
        XCTAssertEqual(seen?.httpMethod, "PROPFIND")
        XCTAssertEqual(page.items.map(\.filename), ["readme.txt"])
    }

    func testClassicFetchContentsTargetsTheItemPath() {
        let account = AccountDescriptor(backend: .classic, serverURL: URL(string: "https://cloud.test")!, username: "admin")
        let connection = BackendConnection(account: account, client: client(status: 200, body: Data()), authorization: nil)

        let request = connection.fetchContentsRequest(path: "/folder/a.txt")

        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.url.absoluteString, "https://cloud.test/remote.php/dav/files/admin/folder/a.txt")
    }

    func testClassicSubfolderEnumerationTargetsItsPathNotItsOCID() async throws {
        // Regression (Task 6.0 live spike): descending into a subfolder must
        // PROPFIND that folder's server-relative PATH. Classic is path-addressed,
        // so an enumerated subfolder's identifier is its path (e.g. "/Documents"),
        // NOT its oc:id — every Classic consumer (fetch/delete/move/subfolder
        // enumeration) treats the identifier as a path, so an oc:id identifier
        // would make the subfolder PROPFIND hit <files-root>/<oc:id>, a
        // nonexistent URL that hangs. Only the root worked because its path is
        // hardcoded to "/".
        var urls: [String] = []
        let account = AccountDescriptor(backend: .classic, serverURL: URL(string: "https://cloud.test")!, username: "admin")
        let rootBody = Data("""
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
          <d:response><d:href>/remote.php/dav/files/admin/</d:href>
            <d:propstat><d:prop><oc:id>root</oc:id><d:resourcetype><d:collection/></d:resourcetype></d:prop>
            <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
          <d:response><d:href>/remote.php/dav/files/admin/Documents/</d:href>
            <d:propstat><d:prop><oc:id>00000011ocsqdq7l97u2</oc:id><d:resourcetype><d:collection/></d:resourcetype></d:prop>
            <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        </d:multistatus>
        """.utf8)
        let connection = BackendConnection(
            account: account,
            client: client(status: 207, body: rootBody, capture: { urls.append($0.url!.absoluteString) }),
            authorization: "Basic abc"
        )

        // Enumerate root and find the Documents folder.
        let rootPage = try await connection.enumerationSource(for: .rootContainer).fetchPage(cursor: nil)
        let documents = try XCTUnwrap(rootPage.items.first)
        XCTAssertEqual(documents.filename, "Documents")
        // Its identifier is the server-relative PATH, so subfolder ops address it.
        XCTAssertEqual(documents.identifier, ItemIdentifier(rawValue: "/Documents"))

        // Descend: the subfolder PROPFIND must hit the Documents PATH, not its oc:id.
        _ = try await connection.enumerationSource(for: documents.identifier).fetchPage(cursor: nil)
        XCTAssertEqual(urls.last, "https://cloud.test/remote.php/dav/files/admin/Documents")
    }

    // MARK: Space WebDAV (oCIS) — ID-addressed

    /// oCIS enumeration and file I/O run over the space's own WebDAV endpoint under
    /// `/dav/spaces`, not Graph — the Graph content endpoints 404 on oCIS 8.2.0
    /// (Task 4.5). Addressing stays by `oc:id`, which oCIS accepts directly as a
    /// WebDAV path and which survives rename and reparent. Every id is a *single*
    /// segment under `/dav/spaces`: the drive id addresses the space root and a
    /// fileid addresses an item, as siblings — `/dav/spaces/{driveID}/{fileID}`
    /// 404s live, because a fileid already begins with the drive id.
    private static let ocisDrive = "drive-1$space-1"
    private static let ocisRootFileID = "drive-1$space-1!space-1"

    /// A Depth:1 space-WebDAV body: the container itself, then one child.
    private func ocisListingBody(
        containerHref: String,
        containerFileID: String,
        childHref: String,
        childFileID: String,
        childName: String
    ) -> Data {
        Data("""
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
          <d:response><d:href>\(containerHref)</d:href>
            <d:propstat><d:prop><oc:id>\(containerFileID)</oc:id><oc:name>container</oc:name>
              <d:resourcetype><d:collection/></d:resourcetype></d:prop>
            <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
          <d:response><d:href>\(childHref)</d:href>
            <d:propstat><d:prop><oc:id>\(childFileID)</oc:id><oc:name>\(childName)</oc:name>
              <oc:file-parent>\(containerFileID)</oc:file-parent>
              <d:resourcetype/><d:getetag>"e"</d:getetag></d:prop>
            <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        </d:multistatus>
        """.utf8)
    }

    private func ocisConnection(
        status: Int = 200,
        body: Data = Data(),
        capture: ((URLRequest) -> Void)? = nil
    ) -> BackendConnection {
        let account = AccountDescriptor(backend: .ocis, serverURL: URL(string: "https://ocis.test")!, username: "einstein")
        return BackendConnection(
            account: account,
            client: client(status: status, body: body, capture: capture),
            authorization: "Bearer t",
            driveID: Self.ocisDrive
        )
    }

    func testOCISRootEnumerationPropfindsTheSpaceWebDAVRoot() async throws {
        var seen: URLRequest?
        let body = ocisListingBody(
            containerHref: "/dav/spaces/drive-1%24space-1/",
            containerFileID: Self.ocisRootFileID,
            childHref: "/dav/spaces/drive-1%24space-1/a.txt",
            childFileID: "\(Self.ocisDrive)!child-1",
            childName: "a.txt")
        let connection = ocisConnection(status: 207, body: body, capture: { seen = $0 })

        let page = try await connection.enumerationSource(for: .rootContainer).fetchPage(cursor: nil)

        // The space root is addressed by the drive id; `$` is percent-encoded per
        // segment and oCIS accepts the escaped form (verified live: 207).
        XCTAssertEqual(seen?.url?.absoluteString, "https://ocis.test/dav/spaces/drive-1%24space-1")
        XCTAssertEqual(seen?.httpMethod, "PROPFIND")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Depth"), "1")
        // The self entry is dropped and the child is identified by its oc:id.
        XCTAssertEqual(page.items.map(\.filename), ["a.txt"])
        XCTAssertEqual(page.items.first?.identifier, ItemIdentifier(rawValue: "\(Self.ocisDrive)!child-1"))
        XCTAssertEqual(page.items.first?.parentIdentifier, .rootContainer)
    }

    func testOCISSubfolderEnumerationPropfindsThatFolderByFileID() async throws {
        var seen: URLRequest?
        let folderID = "\(Self.ocisDrive)!folder-1"
        let body = ocisListingBody(
            containerHref: "/dav/spaces/drive-1%24space-1%21folder-1/",
            containerFileID: folderID,
            childHref: "/dav/spaces/drive-1%24space-1%21folder-1/inner.txt",
            childFileID: "\(Self.ocisDrive)!child-2",
            childName: "inner.txt")
        let connection = ocisConnection(status: 207, body: body, capture: { seen = $0 })

        let page = try await connection.enumerationSource(for: ItemIdentifier(rawValue: folderID))
            .fetchPage(cursor: nil)

        // A subfolder is addressed by its own oc:id; `$` and `!` are escaped.
        XCTAssertEqual(
            seen?.url?.absoluteString,
            "https://ocis.test/dav/spaces/drive-1%24space-1%21folder-1")
        XCTAssertEqual(page.items.map(\.filename), ["inner.txt"])
        // Children of a subfolder are parented to that folder, not the root.
        XCTAssertEqual(page.items.first?.parentIdentifier, ItemIdentifier(rawValue: folderID))
    }

    func testOCISEnumerationDropsTheSelfEntryByFileIDNotByHref() async throws {
        // The self entry cannot be recognised by href: oCIS echoes the request's own
        // percent-encoding in the response href (`%21` when the request escaped `!`),
        // so a literal href comparison against the container address can miss it and
        // leak the container in as a child of itself. Every oCIS entry carries oc:id,
        // so the match is made on that instead.
        let folderID = "\(Self.ocisDrive)!folder-1"
        let body = ocisListingBody(
            containerHref: "/dav/spaces/drive-1%24space-1%21folder-1/",
            containerFileID: folderID,
            childHref: "/dav/spaces/drive-1%24space-1%21folder-1/inner.txt",
            childFileID: "\(Self.ocisDrive)!child-2",
            childName: "inner.txt")
        let connection = ocisConnection(status: 207, body: body)

        let page = try await connection.enumerationSource(for: ItemIdentifier(rawValue: folderID))
            .fetchPage(cursor: nil)

        XCTAssertEqual(page.items.count, 1)
        XCTAssertFalse(page.items.contains { $0.identifier == ItemIdentifier(rawValue: folderID) })
    }

    func testOCISFetchContentsGetsTheItemByFileID() {
        let request = ocisConnection().fetchContentsRequest(itemID: "\(Self.ocisDrive)!item-9")

        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.url.absoluteString, "https://ocis.test/dav/spaces/drive-1%24space-1%21item-9")
    }

    // MARK: Push request shaping — Classic (path-addressed)

    private func classicConnection() -> BackendConnection {
        let account = AccountDescriptor(backend: .classic, serverURL: URL(string: "https://cloud.test")!, username: "admin")
        return BackendConnection(account: account, client: client(status: 200, body: Data()), authorization: nil)
    }

    func testClassicCreateFileTargetsThePathWithPut() {
        let request = classicConnection().createFileRequest(path: "/folder/new.txt")

        XCTAssertEqual(request.method, .put)
        XCTAssertTrue(request.hasBody)
        XCTAssertEqual(request.url.absoluteString, "https://cloud.test/remote.php/dav/files/admin/folder/new.txt")
    }

    func testClassicCreateDirectoryUsesMkcol() {
        let request = classicConnection().createDirectoryRequest(path: "/folder/sub")

        XCTAssertEqual(request.method, .mkcol)
        XCTAssertEqual(request.url.absoluteString, "https://cloud.test/remote.php/dav/files/admin/folder/sub")
    }

    func testClassicModifyContentsSendsIfMatchETag() {
        let request = classicConnection().modifyContentsRequest(path: "/a.txt", ifMatchETag: "\"e1\"")

        XCTAssertEqual(request.method, .put)
        XCTAssertTrue(request.hasBody)
        XCTAssertEqual(request.headers["If-Match"], "\"e1\"")
        XCTAssertEqual(request.url.absoluteString, "https://cloud.test/remote.php/dav/files/admin/a.txt")
    }

    func testClassicDeleteTargetsThePath() {
        let request = classicConnection().deleteRequest(path: "/folder/gone.txt")

        XCTAssertEqual(request.method, .delete)
        XCTAssertEqual(request.url.absoluteString, "https://cloud.test/remote.php/dav/files/admin/folder/gone.txt")
    }

    func testClassicMoveSetsDestinationAndNoOverwrite() {
        let request = classicConnection().moveRequest(fromPath: "/a.txt", toPath: "/b/c.txt")

        XCTAssertEqual(request.method, .move)
        XCTAssertEqual(request.headers["Destination"], "https://cloud.test/remote.php/dav/files/admin/b/c.txt")
        XCTAssertEqual(request.headers["Overwrite"], "F")
    }

    func testClassicReadBackTargetsThePathWithDepthZeroPropfind() {
        // Classic create has no metadata body, so createItem reads the new item
        // back with a Depth:0 PROPFIND on its path.
        let request = classicConnection().readBackRequest(path: "/folder/new.txt")

        XCTAssertEqual(request.method, .propfind)
        XCTAssertEqual(request.headers["Depth"], "0")
        XCTAssertEqual(request.url.absoluteString, "https://cloud.test/remote.php/dav/files/admin/folder/new.txt")
    }

    func testClassicReadBackParsesTheSingleItemUnderTheGivenParent() throws {
        let body = Data("""
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
          <d:response><d:href>/remote.php/dav/files/admin/folder/new.txt</d:href>
            <d:propstat><d:prop>
              <oc:id>server-id-42</oc:id>
              <d:resourcetype/>
              <d:getetag>"etag-after-put"</d:getetag>
              <d:getcontentlength>5</d:getcontentlength>
              <d:getcontenttype>text/plain</d:getcontenttype>
            </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        </d:multistatus>
        """.utf8)

        let description = try classicConnection().readBackItem(
            fromPropfind: body,
            parentIdentifier: ItemIdentifier(rawValue: "/folder")
        )

        // The etag is what createItem could not know before the read-back; the
        // parent is supplied by the caller (WebDAV hrefs don't carry it). The
        // identifier is the item's server-relative PATH (path-addressed backend),
        // i.e. the parent path joined with the name — not the oc:id.
        XCTAssertEqual(description?.identifier, ItemIdentifier(rawValue: "/folder/new.txt"))
        XCTAssertEqual(description?.filename, "new.txt")
        XCTAssertEqual(description?.versionIdentifier, "\"etag-after-put\"")
        XCTAssertEqual(description?.parentIdentifier, ItemIdentifier(rawValue: "/folder"))
        XCTAssertEqual(description?.isDirectory, false)
    }

    func testClassicReadBackReturnsNilForEmptyMultistatus() throws {
        let body = Data("""
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:"></d:multistatus>
        """.utf8)

        let description = try classicConnection().readBackItem(
            fromPropfind: body, parentIdentifier: .rootContainer
        )

        XCTAssertNil(description)
    }

    // MARK: Push request shaping — oCIS (ID-addressed space WebDAV)

    func testOCISModifyContentsPutsToTheItemWithIfMatch() {
        let request = ocisConnection().modifyContentsRequest(
            itemID: "\(Self.ocisDrive)!item-9", ifMatchETag: "\"e2\"")

        XCTAssertEqual(request.method, .put)
        XCTAssertTrue(request.hasBody)
        XCTAssertEqual(request.headers["If-Match"], "\"e2\"")
        XCTAssertEqual(request.url.absoluteString, "https://ocis.test/dav/spaces/drive-1%24space-1%21item-9")
    }

    func testOCISDeleteTargetsTheItemByFileID() {
        let request = ocisConnection().deleteRequest(itemID: "\(Self.ocisDrive)!item-9")

        XCTAssertEqual(request.method, .delete)
        XCTAssertEqual(request.url.absoluteString, "https://ocis.test/dav/spaces/drive-1%24space-1%21item-9")
    }

    func testOCISItemMetadataIsADepthZeroPropfind() {
        // Replaces the Graph `GET /items/{id}`: one Depth:0 PROPFIND yields
        // identifier, parent (oc:file-parent) and name together.
        let request = ocisConnection().itemMetadataRequest(itemID: "\(Self.ocisDrive)!item-9")

        XCTAssertEqual(request.method, .propfind)
        XCTAssertEqual(request.headers["Depth"], "0")
        XCTAssertEqual(request.url.absoluteString, "https://ocis.test/dav/spaces/drive-1%24space-1%21item-9")
    }

    func testOCISMoveUsesMoveWithAnIDAddressedDestination() {
        // Verified live: MOVE by id with an absolute Destination returns 201, and the
        // fileid is unchanged afterwards — across both a rename and a reparent.
        let request = ocisConnection().moveRequest(
            itemID: "\(Self.ocisDrive)!item-9",
            newName: "renamed.txt",
            newParentID: "\(Self.ocisDrive)!parent-2")

        XCTAssertEqual(request.method, .move)
        XCTAssertEqual(request.url.absoluteString, "https://ocis.test/dav/spaces/drive-1%24space-1%21item-9")
        XCTAssertEqual(
            request.headers["Destination"],
            "https://ocis.test/dav/spaces/drive-1%24space-1%21parent-2/renamed.txt")
        // Overwrite: F so a move never clobbers; oCIS answers 412 on collision.
        XCTAssertEqual(request.headers["Overwrite"], "F")
    }

    func testOCISMoveToTheRootAddressesTheSpaceRoot() {
        // A nil new parent means "stay put" (pure rename); the root is the drive id.
        let request = ocisConnection().moveRequest(
            itemID: "\(Self.ocisDrive)!item-9",
            newName: "renamed.txt",
            newParentID: ItemIdentifier.rootContainer.rawValue)

        XCTAssertEqual(
            request.headers["Destination"],
            "https://ocis.test/dav/spaces/drive-1%24space-1/renamed.txt")
    }

    // MARK: create-item routing (root vs. parent, file vs. folder)

    func testOCISCreateFileUnderRootPutsAtTheSpaceRoot() {
        let request = ocisConnection().createItemRequest(
            parentID: .rootContainer, name: "note.txt", isDirectory: false)

        XCTAssertEqual(request.method, .put)
        XCTAssertTrue(request.hasBody)
        XCTAssertEqual(request.url.absoluteString, "https://ocis.test/dav/spaces/drive-1%24space-1/note.txt")
    }

    func testOCISCreateFileUnderParentPutsUnderTheParentFileID() {
        let request = ocisConnection().createItemRequest(
            parentID: ItemIdentifier(rawValue: "\(Self.ocisDrive)!parent-1"),
            name: "note.txt",
            isDirectory: false)

        XCTAssertEqual(request.method, .put)
        XCTAssertEqual(
            request.url.absoluteString,
            "https://ocis.test/dav/spaces/drive-1%24space-1%21parent-1/note.txt")
    }

    func testOCISCreateFolderUnderRootUsesMkcol() {
        let request = ocisConnection().createItemRequest(
            parentID: .rootContainer, name: "New Folder", isDirectory: true)

        XCTAssertEqual(request.method, .mkcol)
        XCTAssertEqual(
            request.url.absoluteString,
            "https://ocis.test/dav/spaces/drive-1%24space-1/New%20Folder")
    }

    func testOCISCreateFolderUnderParentUsesMkcolUnderTheParentFileID() {
        let request = ocisConnection().createItemRequest(
            parentID: ItemIdentifier(rawValue: "\(Self.ocisDrive)!parent-1"),
            name: "New Folder",
            isDirectory: true)

        XCTAssertEqual(request.method, .mkcol)
        XCTAssertEqual(
            request.url.absoluteString,
            "https://ocis.test/dav/spaces/drive-1%24space-1%21parent-1/New%20Folder")
    }

    func testOCISReadBackOfANewItemIsAddressedByNameUnderTheParent() {
        // A just-created item has no oc:id yet — the server assigns it — so the
        // read-back is the one PROPFIND addressed by name, at the same address the
        // create wrote to.
        let request = ocisConnection().readBackNewItemRequest(
            parentID: ItemIdentifier(rawValue: "\(Self.ocisDrive)!parent-1"), name: "note.txt")

        XCTAssertEqual(request.method, .propfind)
        XCTAssertEqual(request.headers["Depth"], "0")
        XCTAssertEqual(
            request.url.absoluteString,
            "https://ocis.test/dav/spaces/drive-1%24space-1%21parent-1/note.txt")
    }

    func testOCISReadBackOfANewItemUnderTheRootUsesTheDriveID() {
        let request = ocisConnection().readBackNewItemRequest(parentID: .rootContainer, name: "note.txt")

        XCTAssertEqual(
            request.url.absoluteString,
            "https://ocis.test/dav/spaces/drive-1%24space-1/note.txt")
    }

    // MARK: oCIS read-back

    func testOCISReadBackParsesTheItemWithItsServerReportedParent() throws {
        // oCIS PUT/MKCOL/MOVE return no body, so create/modify/move read the item
        // back — the same shape as Classic. Unlike Classic the parent comes from the
        // server (oc:file-parent), so the caller does not supply one.
        let body = Data("""
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
          <d:response><d:href>/dav/spaces/drive-1%24space-1%21new-1</d:href>
            <d:propstat><d:prop>
              <oc:id>\(Self.ocisDrive)!new-1</oc:id>
              <oc:name>note.txt</oc:name>
              <oc:file-parent>\(Self.ocisRootFileID)</oc:file-parent>
              <d:resourcetype/><d:getetag>"e9"</d:getetag>
              <d:getcontentlength>12</d:getcontentlength>
              <d:getcontenttype>text/plain</d:getcontenttype>
            </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        </d:multistatus>
        """.utf8)

        let item = try XCTUnwrap(ocisConnection().readBackItem(fromOCISPropfind: body))

        XCTAssertEqual(item.identifier, ItemIdentifier(rawValue: "\(Self.ocisDrive)!new-1"))
        // The root's oc:id normalises to .rootContainer.
        XCTAssertEqual(item.parentIdentifier, .rootContainer)
        XCTAssertEqual(item.filename, "note.txt")
        XCTAssertEqual(item.versionIdentifier, "\"e9\"")
        XCTAssertEqual(item.size, 12)
    }

    func testOCISReadBackReturnsNilForEmptyMultistatus() throws {
        let body = Data("""
        <?xml version="1.0"?><d:multistatus xmlns:d="DAV:"></d:multistatus>
        """.utf8)

        XCTAssertNil(try ocisConnection().readBackItem(fromOCISPropfind: body))
    }
}
