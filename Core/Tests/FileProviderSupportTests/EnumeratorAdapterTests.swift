#if canImport(FileProvider)
import XCTest
import FileProvider
@testable import FileProviderSupport
import OwnCloudCore

/// The `NSFileProviderEnumerator` adapter (progress.md Tasks 3.2/3.3) drives the
/// core `Paginator` / `ChangeSet` and feeds the results to the framework's
/// observers. The page/diff logic lives in OwnCloudCore and is tested there; here
/// we verify the observer plumbing — every page's items are enumerated, the final
/// sync anchor is surfaced, and a change set maps onto update/delete callbacks.
final class EnumeratorAdapterTests: XCTestCase {

    private func desc(_ id: String, version: String = "v1") -> FileProviderItemDescription {
        FileProviderItemDescription(
            identifier: ItemIdentifier(rawValue: id),
            parentIdentifier: .rootContainer,
            filename: "\(id).txt",
            isDirectory: false,
            versionIdentifier: version
        )
    }

    private var firstPage: NSFileProviderPage {
        NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data)
    }

    // MARK: enumerateItems

    func testEnumeratesEveryPageThenFinishesWithoutError() {
        // Two pages, then no cursor.
        let pages = [
            EnumerationPage(items: [desc("a"), desc("b")], nextCursor: PageCursor(rawValue: "p2"), anchor: nil),
            EnumerationPage(items: [desc("c")], nextCursor: nil, anchor: SyncAnchor(token: "final")),
        ]
        var index = 0
        let enumerator = ItemEnumerator(paginator: Paginator { _ in
            defer { index += 1 }
            return pages[index]
        })

        let observer = FakeEnumerationObserver()
        enumerator.enumerateItems(for: observer, startingAt: firstPage)
        observer.wait(self)

        XCTAssertEqual(observer.enumeratedIdentifiers, ["a", "b", "c"])
        XCTAssertNil(observer.finishError)
    }

    func testEnumerateSurfacesFetchErrorToObserver() {
        struct Boom: Error {}
        let enumerator = ItemEnumerator(paginator: Paginator { _ in throw Boom() })

        let observer = FakeEnumerationObserver()
        enumerator.enumerateItems(for: observer, startingAt: firstPage)
        observer.wait(self)

        XCTAssertTrue(observer.enumeratedIdentifiers.isEmpty)
        XCTAssertNotNil(observer.finishError)
    }

    // MARK: enumerateChanges

    func testEnumerateChangesReportsUpdatesDeletionsAndAnchor() {
        let changeSet = ChangeSet(
            updatedItems: [desc("a", version: "v2")],
            deletedIdentifiers: [ItemIdentifier(rawValue: "gone")]
        )
        let enumerator = ItemEnumerator(
            paginator: Paginator { _ in EnumerationPage(items: [], nextCursor: nil, anchor: nil) },
            changeProvider: { _ in (changeSet, SyncAnchor(token: "anchor-2")) }
        )

        let observer = FakeChangeObserver()
        let from = NSFileProviderSyncAnchor(SyncAnchor(token: "anchor-1").data)
        enumerator.enumerateChanges(for: observer, from: from)
        observer.wait(self)

        XCTAssertEqual(observer.updatedIdentifiers, ["a"])
        XCTAssertEqual(observer.deletedIdentifiers, ["gone"])
        XCTAssertEqual(observer.finalAnchor, SyncAnchor(token: "anchor-2").data)
        XCTAssertNil(observer.finishError)
    }

    func testEnumerateChangesSurfacesErrorToObserver() {
        struct Boom: Error {}
        let enumerator = ItemEnumerator(
            paginator: Paginator { _ in EnumerationPage(items: [], nextCursor: nil, anchor: nil) },
            changeProvider: { _ in throw Boom() }
        )

        let observer = FakeChangeObserver()
        enumerator.enumerateChanges(for: observer, from: NSFileProviderSyncAnchor(Data()))
        observer.wait(self)

        XCTAssertNotNil(observer.finishError)
    }

    // MARK: currentSyncAnchor

    func testCurrentSyncAnchorReflectsLatestEnumeration() {
        let enumerator = ItemEnumerator(
            paginator: Paginator { _ in
                EnumerationPage(items: [self.desc("a")], nextCursor: nil, anchor: SyncAnchor(token: "abc"))
            }
        )

        // Before any enumeration there is no anchor yet.
        XCTAssertNil(currentAnchor(of: enumerator))

        let observer = FakeEnumerationObserver()
        enumerator.enumerateItems(for: observer, startingAt: firstPage)
        observer.wait(self)

        XCTAssertEqual(currentAnchor(of: enumerator), SyncAnchor(token: "abc").data)
    }

    private func currentAnchor(of enumerator: ItemEnumerator) -> Data? {
        let exp = expectation(description: "anchor")
        var received: NSFileProviderSyncAnchor?
        enumerator.currentSyncAnchor { received = $0; exp.fulfill() }
        wait(for: [exp], timeout: 2)
        return received?.rawValue
    }
}

// MARK: - Fakes

private final class FakeEnumerationObserver: NSObject, NSFileProviderEnumerationObserver {
    var enumeratedIdentifiers: [String] = []
    var finishError: Error?
    private let done = XCTestExpectation(description: "enumeration finished")

    func didEnumerate(_ updatedItems: [NSFileProviderItemProtocol]) {
        enumeratedIdentifiers.append(contentsOf: updatedItems.map { $0.itemIdentifier.rawValue })
    }
    func finishEnumerating(upTo nextPage: NSFileProviderPage?) { done.fulfill() }
    func finishEnumeratingWithError(_ error: Error) { finishError = error; done.fulfill() }

    func wait(_ test: XCTestCase) { test.wait(for: [done], timeout: 5) }
}

private final class FakeChangeObserver: NSObject, NSFileProviderChangeObserver {
    var updatedIdentifiers: [String] = []
    var deletedIdentifiers: [String] = []
    var finalAnchor: Data?
    var finishError: Error?
    private let done = XCTestExpectation(description: "changes finished")

    func didUpdate(_ updatedItems: [NSFileProviderItemProtocol]) {
        updatedIdentifiers.append(contentsOf: updatedItems.map { $0.itemIdentifier.rawValue })
    }
    func didDeleteItems(withIdentifiers deletedItemIdentifiers: [NSFileProviderItemIdentifier]) {
        deletedIdentifiers.append(contentsOf: deletedItemIdentifiers.map { $0.rawValue })
    }
    func finishEnumeratingChanges(upTo anchor: NSFileProviderSyncAnchor, moreComing: Bool) {
        finalAnchor = anchor.rawValue; done.fulfill()
    }
    func finishEnumeratingWithError(_ error: Error) { finishError = error; done.fulfill() }

    func wait(_ test: XCTestCase) { test.wait(for: [done], timeout: 5) }
}
#endif
