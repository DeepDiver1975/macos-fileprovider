import XCTest
@testable import OwnCloudCore

/// Tasks 3.2 / 3.3: enumeration with pagination + sync anchors, and change
/// tracking (additions / modifications / deletions) against a `from:` anchor.
///
/// The `NSFileProviderEnumerator` / `NSFileProviderChangeObserver` conformances
/// are the Mac-only adapters; the accumulation and diff logic lives in the core
/// and is what these tests drive.
final class EnumerationTests: XCTestCase {

    // MARK: - Sync anchor

    func testSyncAnchorRoundTripsThroughData() {
        let anchor = SyncAnchor(token: "delta-token-123")
        let restored = SyncAnchor(data: anchor.data)
        XCTAssertEqual(restored, anchor)
        XCTAssertEqual(restored?.token, "delta-token-123")
    }

    func testSyncAnchorFromEmptyDataIsNil() {
        XCTAssertNil(SyncAnchor(data: Data()))
    }

    // MARK: - Pagination accumulation

    func testPaginatorAccumulatesAllPagesUntilNoCursor() throws {
        // Three pages: A → B → (final, carries the sync anchor).
        let pages: [String?: EnumerationPage] = [
            nil: EnumerationPage(items: [desc("a")], nextCursor: PageCursor(rawValue: "p2"), anchor: nil),
            "p2": EnumerationPage(items: [desc("b")], nextCursor: PageCursor(rawValue: "p3"), anchor: nil),
            "p3": EnumerationPage(items: [desc("c")], nextCursor: nil, anchor: SyncAnchor(token: "final")),
        ]
        let paginator = Paginator { cursor in pages[cursor?.rawValue]! }

        let result = try paginator.enumerateAll()

        XCTAssertEqual(result.items.map(\.filename), ["a", "b", "c"])
        XCTAssertEqual(result.anchor, SyncAnchor(token: "final"))
    }

    func testPaginatorStopsAtSinglePage() throws {
        let paginator = Paginator { _ in
            EnumerationPage(items: [self.desc("only")], nextCursor: nil, anchor: SyncAnchor(token: "t"))
        }
        let result = try paginator.enumerateAll()
        XCTAssertEqual(result.items.map(\.filename), ["only"])
    }

    // MARK: - Change diffing (Task 3.3)

    func testChangeSetDetectsAdditions() {
        let old = [desc("a", version: "1")]
        let new = [desc("a", version: "1"), desc("b", version: "1")]
        let changes = ChangeSet(from: old, to: new)

        XCTAssertEqual(changes.updatedItems.map(\.filename), ["b"])
        XCTAssertTrue(changes.deletedIdentifiers.isEmpty)
    }

    func testChangeSetDetectsModificationsByVersion() {
        let old = [desc("a", version: "1"), desc("b", version: "1")]
        let new = [desc("a", version: "2"), desc("b", version: "1")]
        let changes = ChangeSet(from: old, to: new)

        // Only "a" changed version; "b" unchanged is not reported.
        XCTAssertEqual(changes.updatedItems.map(\.filename), ["a"])
        XCTAssertTrue(changes.deletedIdentifiers.isEmpty)
    }

    func testChangeSetDetectsDeletions() {
        let old = [desc("a", version: "1"), desc("gone", version: "1")]
        let new = [desc("a", version: "1")]
        let changes = ChangeSet(from: old, to: new)

        XCTAssertTrue(changes.updatedItems.isEmpty)
        XCTAssertEqual(changes.deletedIdentifiers, [ItemIdentifier(rawValue: "gone")])
    }

    func testChangeSetCombinesAllThree() {
        let old = [desc("keep", version: "1"), desc("mod", version: "1"), desc("del", version: "1")]
        let new = [desc("keep", version: "1"), desc("mod", version: "2"), desc("add", version: "1")]
        let changes = ChangeSet(from: old, to: new)

        XCTAssertEqual(Set(changes.updatedItems.map(\.filename)), ["mod", "add"])
        XCTAssertEqual(changes.deletedIdentifiers, [ItemIdentifier(rawValue: "del")])
    }

    func testChangeSetFromGraphDeltaMarksDeletedFacetAsDeletion() {
        // A Graph delta page carries live + deleted items in one list.
        let live = GraphItem(id: "live", name: "live.txt", size: 1, eTag: "\"1\"", lastModified: nil,
                             isFolder: false, childCount: nil, mimeType: "text/plain",
                             parentDriveID: "d", parentID: "d!root", isDeleted: false)
        let dead = GraphItem(id: "dead", name: "dead.txt", size: nil, eTag: nil, lastModified: nil,
                             isFolder: false, childCount: nil, mimeType: nil,
                             parentDriveID: "d", parentID: "d!root", isDeleted: true)
        let changes = ChangeSet(graphDelta: [live, dead])

        XCTAssertEqual(changes.updatedItems.map(\.filename), ["live.txt"])
        XCTAssertEqual(changes.deletedIdentifiers, [ItemIdentifier(rawValue: "dead")])
    }

    // MARK: - Helpers

    private func desc(_ name: String, version: String? = nil) -> FileProviderItemDescription {
        FileProviderItemDescription(
            identifier: ItemIdentifier(rawValue: name),
            parentIdentifier: .rootContainer,
            filename: name,
            isDirectory: false,
            versionIdentifier: version
        )
    }
}
