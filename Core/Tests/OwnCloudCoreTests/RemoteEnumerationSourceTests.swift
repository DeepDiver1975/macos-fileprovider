import XCTest
@testable import OwnCloudCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The live-fetch seam that was the last headless gap in enumeration
/// (progress.md Phase 3 note: "wiring a builder+parser into a live
/// `Paginator.FetchPage` via `RemoteClient`"). A `RemoteEnumerationSource`
/// issues the enumerate request its builder shapes, parses/decodes the response,
/// and maps it onto an ``EnumerationPage`` — the WebDAV and Graph clients plugged
/// into the pagination engine without the engine knowing either protocol.
///
/// Driven with an injected `RemoteClient` performer returning fixture bytes, so
/// no live server is needed and the type stays Linux-buildable (AC-2).
final class RemoteEnumerationSourceTests: XCTestCase {

    // A Depth:1 PROPFIND body: the container itself, one file child, one folder.
    private let webDAVBody = Data("""
    <?xml version="1.0"?>
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:response>
        <d:href>/remote.php/dav/files/admin/Photos/</d:href>
        <d:propstat><d:prop>
          <oc:id>root-15</oc:id>
          <d:resourcetype><d:collection/></d:resourcetype>
          <d:getetag>"root-etag"</d:getetag>
        </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
      </d:response>
      <d:response>
        <d:href>/remote.php/dav/files/admin/Photos/a.jpg</d:href>
        <d:propstat><d:prop>
          <oc:id>id-a</oc:id>
          <d:resourcetype/>
          <d:getcontentlength>10</d:getcontentlength>
          <d:getetag>"etag-a"</d:getetag>
        </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
      </d:response>
      <d:response>
        <d:href>/remote.php/dav/files/admin/Photos/sub/</d:href>
        <d:propstat><d:prop>
          <oc:id>id-sub</oc:id>
          <d:resourcetype><d:collection/></d:resourcetype>
          <d:getetag>"etag-sub"</d:getetag>
        </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
      </d:response>
    </d:multistatus>
    """.utf8)

    private func client(
        status: Int = 207,
        body: Data,
        capture: ((URLRequest) -> Void)? = nil
    ) -> RemoteClient {
        RemoteClient { urlRequest in
            capture?(urlRequest)
            let response = HTTPURLResponse(
                url: urlRequest.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (body, response)
        }
    }

    // MARK: - WebDAV

    func testWebDAVSourceFetchesParsesAndDropsSelfEntry() async throws {
        let source = WebDAVEnumerationSource(
            client: client(body: webDAVBody),
            builder: WebDAVRequestBuilder(filesBaseURL: URL(string: "https://cloud.test/remote.php/dav/files/admin")!),
            containerPath: "/Photos",
            containerHref: "/remote.php/dav/files/admin/Photos",
            parentIdentifier: .rootContainer,
            authorization: "Basic YWRtaW46YWRtaW4="
        )

        let page = try await source.fetchPage(cursor: nil)

        // The Depth:1 self-entry is dropped; only the children remain.
        XCTAssertEqual(page.items.map(\.filename), ["a.jpg", "sub"])
        // Classic lists everything at once — no next cursor.
        XCTAssertNil(page.nextCursor)
    }

    func testWebDAVSourceIssuesPropfindWithAuthorization() async throws {
        var seen: URLRequest?
        let source = WebDAVEnumerationSource(
            client: client(body: webDAVBody, capture: { seen = $0 }),
            builder: WebDAVRequestBuilder(filesBaseURL: URL(string: "https://cloud.test/remote.php/dav/files/admin")!),
            containerPath: "/Photos",
            containerHref: "/remote.php/dav/files/admin/Photos",
            parentIdentifier: .rootContainer,
            authorization: "Basic YWRtaW46YWRtaW4="
        )

        _ = try await source.fetchPage(cursor: nil)

        XCTAssertEqual(seen?.httpMethod, "PROPFIND")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Depth"), "1")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Basic YWRtaW46YWRtaW4=")
    }

    func testWebDAVSourceSynthesizesAListingAnchor() async throws {
        let source = WebDAVEnumerationSource(
            client: client(body: webDAVBody),
            builder: WebDAVRequestBuilder(filesBaseURL: URL(string: "https://cloud.test/remote.php/dav/files/admin")!),
            containerPath: "/Photos",
            containerHref: "/remote.php/dav/files/admin/Photos",
            parentIdentifier: .rootContainer,
            authorization: nil
        )

        let page = try await source.fetchPage(cursor: nil)

        // WebDAV has no delta API: the anchor is synthesized from the children,
        // matching SyncAnchor(listing:) so enumerateChanges can compare.
        XCTAssertEqual(page.anchor, SyncAnchor(listing: page.items))
        XCTAssertNotNil(page.anchor)
    }

    func testWebDAVSourceThrowsClassifiedErrorOnFailureStatus() async {
        let source = WebDAVEnumerationSource(
            client: client(status: 401, body: Data()),
            builder: WebDAVRequestBuilder(filesBaseURL: URL(string: "https://cloud.test/remote.php/dav/files/admin")!),
            containerPath: "/Photos",
            containerHref: "/remote.php/dav/files/admin/Photos",
            parentIdentifier: .rootContainer,
            authorization: nil
        )
        do {
            _ = try await source.fetchPage(cursor: nil)
            XCTFail("expected a thrown error")
        } catch let error as RemoteError {
            XCTAssertEqual(error, .authenticationRequired)
        } catch {
            XCTFail("expected RemoteError, got \(error)")
        }
    }

    // MARK: - Graph

    private func graphBody(nextLink: String?, deltaLink: String?) -> Data {
        let links = [
            nextLink.map { "\"@odata.nextLink\": \"\($0)\"," } ?? "",
            deltaLink.map { "\"@odata.deltaLink\": \"\($0)\"," } ?? "",
        ].joined()
        return Data("""
        {
          \(links)
          "value": [
            { "id": "1", "name": "a.txt", "size": 10, "eTag": "e1", "file": { "mimeType": "text/plain" } },
            { "id": "2", "name": "b.txt", "size": 20, "eTag": "e2", "file": { "mimeType": "text/plain" } }
          ]
        }
        """.utf8)
    }

    func testGraphSourceFetchesAndMapsCollection() async throws {
        let source = GraphEnumerationSource(
            client: client(status: 200, body: graphBody(nextLink: "https://ocis.test/graph?$token=page2", deltaLink: nil)),
            builder: GraphRequestBuilder(baseURL: URL(string: "https://ocis.test")!),
            driveID: "drive-1",
            itemID: "drive-1",
            authorization: "Bearer xyz"
        )

        let page = try await source.fetchPage(cursor: nil)

        XCTAssertEqual(page.items.map(\.filename), ["a.txt", "b.txt"])
        XCTAssertEqual(page.nextCursor, PageCursor(rawValue: "page2"))
        XCTAssertNil(page.anchor)  // only the delta (final) page carries the anchor
    }

    func testGraphSourceFinalPageCarriesDeltaAnchor() async throws {
        let source = GraphEnumerationSource(
            client: client(status: 200, body: graphBody(nextLink: nil, deltaLink: "https://ocis.test/graph?$token=sync-9")),
            builder: GraphRequestBuilder(baseURL: URL(string: "https://ocis.test")!),
            driveID: "drive-1",
            itemID: "drive-1",
            authorization: "Bearer xyz"
        )

        let page = try await source.fetchPage(cursor: nil)

        XCTAssertNil(page.nextCursor)
        XCTAssertEqual(page.anchor, SyncAnchor(token: "sync-9"))
    }

    func testGraphSourceFollowsCursorToDeltaEndpoint() async throws {
        var seen: URLRequest?
        let source = GraphEnumerationSource(
            client: client(status: 200, body: graphBody(nextLink: nil, deltaLink: "https://ocis.test/graph?$token=done"), capture: { seen = $0 }),
            builder: GraphRequestBuilder(baseURL: URL(string: "https://ocis.test")!),
            driveID: "drive-1",
            itemID: "drive-1",
            authorization: "Bearer xyz"
        )

        _ = try await source.fetchPage(cursor: PageCursor(rawValue: "page2"))

        // A cursor drives the item's /delta endpoint (which also powers change tracking).
        XCTAssertEqual(seen?.url?.absoluteString, "https://ocis.test/graph/v1.0/drives/drive-1/items/drive-1/delta?$token=page2")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Bearer xyz")
    }

    // MARK: - Async multi-page walk

    func testAccumulatesAllPagesInOrderAndKeepsFinalAnchor() async throws {
        // A source that vends two pages then stops, to prove the async walk
        // follows cursors to completion and captures the terminal anchor.
        let source = ScriptedSource(pages: [
            EnumerationPage(items: [item("1", "a.txt")], nextCursor: PageCursor(rawValue: "p2"), anchor: nil),
            EnumerationPage(items: [item("2", "b.txt")], nextCursor: nil, anchor: SyncAnchor(token: "final")),
        ])

        let result = try await enumerateAll(from: source)

        XCTAssertEqual(result.items.map(\.filename), ["a.txt", "b.txt"])
        XCTAssertEqual(result.anchor, SyncAnchor(token: "final"))
    }

    private func item(_ id: String, _ name: String) -> FileProviderItemDescription {
        FileProviderItemDescription(
            identifier: ItemIdentifier(rawValue: id),
            parentIdentifier: .rootContainer,
            filename: name,
            isDirectory: false,
            versionIdentifier: "v"
        )
    }

    /// A source that replays a fixed list of pages, following its own cursors.
    private struct ScriptedSource: RemoteEnumerationSource {
        let pages: [EnumerationPage]
        func fetchPage(cursor: PageCursor?) async throws -> EnumerationPage {
            guard let cursor else { return pages[0] }
            // The scripted cursors are "p2", "p3", … → index 1, 2, …
            let index = Int(cursor.rawValue.dropFirst()) ?? 1
            return pages[index - 1]
        }
    }
}
