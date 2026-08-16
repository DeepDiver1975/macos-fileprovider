import XCTest
@testable import OwnCloudCore

/// ownCloud Classic (WebDAV) has no delta API, so the enumerator re-lists and
/// diffs (`ChangeSet(from:to:)`). To decide *whether* to re-list, the system
/// stores and replays a `NSFileProviderSyncAnchor`; for WebDAV that anchor is a
/// synthesized digest of the current listing (progress.md `SyncAnchor` note).
/// The digest must be deterministic, order-independent, and change iff any
/// item's identity or version changed.
final class WebDAVSyncAnchorTests: XCTestCase {

    private func item(_ id: String, version: String) -> FileProviderItemDescription {
        FileProviderItemDescription(
            identifier: ItemIdentifier(rawValue: id),
            parentIdentifier: .rootContainer,
            filename: "\(id).txt",
            isDirectory: false,
            versionIdentifier: version
        )
    }

    func testSameListingProducesSameAnchor() {
        let a = SyncAnchor(listing: [item("1", version: "v1"), item("2", version: "v1")])
        let b = SyncAnchor(listing: [item("1", version: "v1"), item("2", version: "v1")])
        XCTAssertEqual(a, b)
    }

    func testOrderDoesNotAffectAnchor() {
        let a = SyncAnchor(listing: [item("1", version: "v1"), item("2", version: "v2")])
        let b = SyncAnchor(listing: [item("2", version: "v2"), item("1", version: "v1")])
        XCTAssertEqual(a, b)
    }

    func testChangedVersionChangesAnchor() {
        let a = SyncAnchor(listing: [item("1", version: "v1")])
        let b = SyncAnchor(listing: [item("1", version: "v2")])
        XCTAssertNotEqual(a, b)
    }

    func testAddedItemChangesAnchor() {
        let a = SyncAnchor(listing: [item("1", version: "v1")])
        let b = SyncAnchor(listing: [item("1", version: "v1"), item("2", version: "v1")])
        XCTAssertNotEqual(a, b)
    }

    func testRemovedItemChangesAnchor() {
        let a = SyncAnchor(listing: [item("1", version: "v1"), item("2", version: "v1")])
        let b = SyncAnchor(listing: [item("1", version: "v1")])
        XCTAssertNotEqual(a, b)
    }

    func testEmptyListingHasAStableAnchor() {
        XCTAssertEqual(SyncAnchor(listing: []), SyncAnchor(listing: []))
    }

    func testAnchorRoundTripsThroughData() {
        let anchor = SyncAnchor(listing: [item("1", version: "v1")])
        XCTAssertEqual(SyncAnchor(data: anchor.data), anchor)
    }
}
