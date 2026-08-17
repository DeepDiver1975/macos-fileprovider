import XCTest
@testable import OwnCloudCore

/// Task 4.3: local file modification detection and upload queuing.
///
/// When the system reports a locally-changed item, the extension must decide
/// whether it is genuinely new/modified relative to what the server last had,
/// and enqueue an upload without duplicating an already-pending one. That
/// bookkeeping is pure and lives in the core.
final class UploadQueueTests: XCTestCase {

    func testEnqueuesNewItem() {
        var queue = UploadQueue()
        let enqueued = queue.enqueueIfChanged(
            identifier: ItemIdentifier(rawValue: "a"),
            localVersion: "v1",
            lastSyncedVersion: nil
        )
        XCTAssertTrue(enqueued)
        XCTAssertEqual(queue.pendingIdentifiers, [ItemIdentifier(rawValue: "a")])
    }

    func testEnqueuesModifiedItemWhenVersionDiffers() {
        var queue = UploadQueue()
        let enqueued = queue.enqueueIfChanged(
            identifier: ItemIdentifier(rawValue: "a"),
            localVersion: "v2",
            lastSyncedVersion: "v1"
        )
        XCTAssertTrue(enqueued)
    }

    func testDoesNotEnqueueUnchangedItem() {
        var queue = UploadQueue()
        let enqueued = queue.enqueueIfChanged(
            identifier: ItemIdentifier(rawValue: "a"),
            localVersion: "v1",
            lastSyncedVersion: "v1"
        )
        XCTAssertFalse(enqueued)
        XCTAssertTrue(queue.pendingIdentifiers.isEmpty)
    }

    func testDoesNotDuplicateAlreadyPendingItem() {
        var queue = UploadQueue()
        _ = queue.enqueueIfChanged(identifier: ItemIdentifier(rawValue: "a"), localVersion: "v1", lastSyncedVersion: nil)
        let second = queue.enqueueIfChanged(identifier: ItemIdentifier(rawValue: "a"), localVersion: "v2", lastSyncedVersion: nil)
        XCTAssertFalse(second)
        XCTAssertEqual(queue.pendingIdentifiers.count, 1)
    }

    func testDequeueRemovesAndReturnsInFIFOOrder() {
        var queue = UploadQueue()
        _ = queue.enqueueIfChanged(identifier: ItemIdentifier(rawValue: "a"), localVersion: "1", lastSyncedVersion: nil)
        _ = queue.enqueueIfChanged(identifier: ItemIdentifier(rawValue: "b"), localVersion: "1", lastSyncedVersion: nil)

        XCTAssertEqual(queue.dequeue(), ItemIdentifier(rawValue: "a"))
        XCTAssertEqual(queue.dequeue(), ItemIdentifier(rawValue: "b"))
        XCTAssertNil(queue.dequeue())
    }

    func testDequeuedItemCanBeReEnqueuedAfterFurtherChange() {
        var queue = UploadQueue()
        _ = queue.enqueueIfChanged(identifier: ItemIdentifier(rawValue: "a"), localVersion: "v1", lastSyncedVersion: nil)
        _ = queue.dequeue()
        let again = queue.enqueueIfChanged(identifier: ItemIdentifier(rawValue: "a"), localVersion: "v2", lastSyncedVersion: "v1")
        XCTAssertTrue(again)
        XCTAssertEqual(queue.pendingIdentifiers, [ItemIdentifier(rawValue: "a")])
    }
}
