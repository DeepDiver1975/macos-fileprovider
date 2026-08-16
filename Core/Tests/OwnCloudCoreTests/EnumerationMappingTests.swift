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

    // MARK: - Graph

    private func graphItem(id: String, name: String) -> GraphItem {
        GraphItem(
            id: id, name: name, size: 1, eTag: "e", lastModified: nil,
            isFolder: false, childCount: nil, mimeType: "text/plain",
            parentDriveID: nil, parentID: nil, isDeleted: false
        )
    }

    func testGraphPageMapsItemsAndCarriesNextTokenAsCursor() {
        let collection = GraphItemCollection(
            items: [graphItem(id: "1", name: "a.txt"), graphItem(id: "2", name: "b.txt")],
            deltaToken: nil,
            nextToken: "page2"
        )
        let page = EnumerationPage(graphCollection: collection)
        XCTAssertEqual(page.items.map(\.filename), ["a.txt", "b.txt"])
        XCTAssertEqual(page.nextCursor, PageCursor(rawValue: "page2"))
        // Only the final page (deltaLink) carries the anchor.
        XCTAssertNil(page.anchor)
    }

    func testGraphFinalPageCarriesDeltaTokenAsAnchorAndNoCursor() {
        let collection = GraphItemCollection(
            items: [graphItem(id: "1", name: "a.txt")],
            deltaToken: "sync-9",
            nextToken: nil
        )
        let page = EnumerationPage(graphCollection: collection)
        XCTAssertNil(page.nextCursor)
        XCTAssertEqual(page.anchor, SyncAnchor(token: "sync-9"))
    }
}
