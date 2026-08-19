import XCTest
@testable import OwnCloudCore

/// The pure mapping of a parsed backend enumeration response onto the engine's
/// `EnumerationPage` (progress.md Phase 3) — the half of `Paginator.FetchPage`
/// that has no networking. WebDAV Depth:1 lists the container itself alongside
/// its children (which must be dropped) and has no paging token; Graph carries
/// `$token`s that become the next cursor and the sync anchor.
final class EnumerationMappingTests: XCTestCase {

    // MARK: - WebDAV

    private func davItem(href: String, isDirectory: Bool, etag: String? = "e") -> WebDAVItem {
        WebDAVItem(href: href, isDirectory: isDirectory, fileID: href, etag: etag)
    }

    func testWebDAVPageDropsTheContainerSelfEntry() {
        let items = [
            davItem(href: "/remote.php/dav/files/admin/Photos/", isDirectory: true),   // the container itself
            davItem(href: "/remote.php/dav/files/admin/Photos/a.jpg", isDirectory: false),
            davItem(href: "/remote.php/dav/files/admin/Photos/sub/", isDirectory: true),
        ]
        let page = EnumerationPage(
            webDAVItems: items,
            containerHref: "/remote.php/dav/files/admin/Photos",
            parentIdentifier: .rootContainer
        )
        XCTAssertEqual(page.items.map(\.filename), ["a.jpg", "sub"])
    }

    func testWebDAVPageSetsParentAndHasNoCursor() {
        let items = [
            davItem(href: "/remote.php/dav/files/admin/", isDirectory: true),          // root container self
            davItem(href: "/remote.php/dav/files/admin/report.txt", isDirectory: false),
        ]
        let parent = ItemIdentifier(rawValue: "parent-1")
        let page = EnumerationPage(
            webDAVItems: items,
            containerHref: "/remote.php/dav/files/admin/",
            parentIdentifier: parent
        )
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items.first?.parentIdentifier, parent)
        // Classic PROPFIND returns every child in one shot — no pagination.
        XCTAssertNil(page.nextCursor)
    }

    func testWebDAVEmptyFolderYieldsEmptyPage() {
        let items = [davItem(href: "/remote.php/dav/files/admin/Empty/", isDirectory: true)]
        let page = EnumerationPage(
            webDAVItems: items,
            containerHref: "/remote.php/dav/files/admin/Empty",
            parentIdentifier: .rootContainer
        )
        XCTAssertTrue(page.items.isEmpty)
    }

    // MARK: - oCIS space WebDAV (Task 4.5)

    private static let drive = "drive-1$space-1"
    private static let rootFileID = "drive-1$space-1!space-1"

    private func ocisItem(
        fileID: String,
        name: String,
        parentFileID: String?,
        isDirectory: Bool = false
    ) -> WebDAVItem {
        WebDAVItem(
            href: "/dav/spaces/drive-1%24space-1/\(name)",
            isDirectory: isDirectory,
            fileID: fileID,
            etag: "\"e\"",
            contentLength: isDirectory ? nil : 1,
            contentType: isDirectory ? nil : "text/plain",
            parentFileID: parentFileID,
            serverName: name
        )
    }

    func testOCISPageDropsTheSpaceRootSelfEntry() {
        // Enumerating the space root: the self entry's oc:id is the root's, which is
        // not the bare driveID, so it is recognised structurally rather than by a
        // caller-supplied container id.
        let items = [
            ocisItem(fileID: Self.rootFileID, name: "", parentFileID: Self.drive, isDirectory: true),
            ocisItem(fileID: "\(Self.drive)!c1", name: "a.txt", parentFileID: Self.rootFileID),
        ]
        let page = EnumerationPage(ocisWebDAVItems: items, containerFileID: nil, driveID: Self.drive)

        XCTAssertEqual(page.items.map(\.filename), ["a.txt"])
        XCTAssertEqual(page.items.first?.parentIdentifier, .rootContainer)
    }

    func testOCISPageDropsASubfolderSelfEntryByFileID() {
        let folderID = "\(Self.drive)!folder-1"
        let items = [
            ocisItem(fileID: folderID, name: "folder", parentFileID: Self.rootFileID, isDirectory: true),
            ocisItem(fileID: "\(Self.drive)!c2", name: "inner.txt", parentFileID: folderID),
        ]
        let page = EnumerationPage(ocisWebDAVItems: items, containerFileID: folderID, driveID: Self.drive)

        XCTAssertEqual(page.items.map(\.filename), ["inner.txt"])
        XCTAssertEqual(page.items.first?.parentIdentifier, ItemIdentifier(rawValue: folderID))
    }

    func testOCISPageMatchesTheSelfEntryEvenWhenTheHrefEncodingDiffers() {
        // The reason the match is on oc:id: oCIS echoes the request's percent-encoding
        // in the href, so the container listed as `…%21folder-1` cannot be compared
        // literally against an address spelled with `!`.
        let folderID = "\(Self.drive)!folder-1"
        let selfEntry = WebDAVItem(
            href: "/dav/spaces/drive-1%24space-1%21folder-1/",
            isDirectory: true,
            fileID: folderID,
            parentFileID: Self.rootFileID,
            serverName: "folder")
        let page = EnumerationPage(
            ocisWebDAVItems: [selfEntry, ocisItem(fileID: "\(Self.drive)!c3", name: "x.txt", parentFileID: folderID)],
            containerFileID: folderID,
            driveID: Self.drive)

        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items.first?.filename, "x.txt")
    }

    func testOCISPageHasNoCursorOrAnchor() {
        // oCIS space WebDAV has no delta token, exactly like Classic: one page, and
        // the anchor is synthesized from the listing by the enumeration source.
        let page = EnumerationPage(
            ocisWebDAVItems: [ocisItem(fileID: "\(Self.drive)!c1", name: "a.txt", parentFileID: Self.rootFileID)],
            containerFileID: Self.rootFileID,
            driveID: Self.drive)

        XCTAssertNil(page.nextCursor)
        XCTAssertNil(page.anchor)
    }

    func testOCISPageKeepsItemsThatLackAFileID() {
        // Defensive: an entry without oc:id cannot be the container (the container's
        // id is known), so it is kept rather than silently dropped.
        let items = [WebDAVItem(href: "/dav/spaces/drive-1%24space-1/odd.txt", isDirectory: false, serverName: "odd.txt")]
        let page = EnumerationPage(ocisWebDAVItems: items, containerFileID: Self.rootFileID, driveID: Self.drive)

        XCTAssertEqual(page.items.map(\.filename), ["odd.txt"])
    }
}
