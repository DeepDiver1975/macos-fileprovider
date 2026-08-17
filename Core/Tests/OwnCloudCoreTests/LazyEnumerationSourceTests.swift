import XCTest
@testable import OwnCloudCore

/// A `LazyRemoteEnumerationSource` defers building the real source until the first
/// page is fetched — needed because oCIS enumeration requires a `driveID` that is
/// only known after an async `me/drives` lookup, while the Mac enumerator builds
/// its source synchronously.
final class LazyEnumerationSourceTests: XCTestCase {

    /// A trivial source returning one fixed page, recording how often it was built.
    private struct StubSource: RemoteEnumerationSource {
        let item: FileProviderItemDescription
        func fetchPage(cursor: PageCursor?) async throws -> EnumerationPage {
            EnumerationPage(items: [item], nextCursor: nil, anchor: nil)
        }
    }

    private func description(_ name: String) -> FileProviderItemDescription {
        FileProviderItemDescription(
            identifier: ItemIdentifier(rawValue: name), parentIdentifier: .rootContainer,
            filename: name, isDirectory: false, size: 0, versionIdentifier: nil,
            contentType: nil, contentModificationDate: nil, capabilities: .readWrite
        )
    }

    func testBuildsTheUnderlyingSourceOnFirstFetch() async throws {
        let source = LazyRemoteEnumerationSource { StubSource(item: self.description("a.txt")) }

        let page = try await source.fetchPage(cursor: nil)

        XCTAssertEqual(page.items.map(\.filename), ["a.txt"])
    }

    func testBuildsTheUnderlyingSourceOnlyOnce() async throws {
        let builds = Counter()
        let source = LazyRemoteEnumerationSource {
            await builds.increment()
            return StubSource(item: self.description("a.txt"))
        }

        _ = try await source.fetchPage(cursor: nil)
        _ = try await source.fetchPage(cursor: nil)

        let count = await builds.value
        XCTAssertEqual(count, 1, "the factory must run once and be cached")
    }

    func testPropagatesFactoryErrors() async {
        struct BoomError: Error {}
        let source = LazyRemoteEnumerationSource { throw BoomError() }

        do {
            _ = try await source.fetchPage(cursor: nil)
            XCTFail("expected the factory error to propagate")
        } catch is BoomError {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }
}
