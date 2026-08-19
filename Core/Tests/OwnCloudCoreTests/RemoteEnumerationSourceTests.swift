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

    // MARK: - oCIS space WebDAV (Task 4.5)

    private static let ocisDrive = "drive-1$space-1"
    private static let ocisRootFileID = "drive-1$space-1!space-1"

    /// A Depth:1 space-WebDAV body: the container itself, then two children.
    private func ocisBody(containerFileID: String) -> Data {
        Data("""
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
          <d:response><d:href>/dav/spaces/drive-1%24space-1/</d:href>
            <d:propstat><d:prop><oc:id>\(containerFileID)</oc:id><oc:name>container</oc:name>
              <d:resourcetype><d:collection/></d:resourcetype></d:prop>
            <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
          <d:response><d:href>/dav/spaces/drive-1%24space-1/a.txt</d:href>
            <d:propstat><d:prop><oc:id>\(Self.ocisDrive)!c1</oc:id><oc:name>a.txt</oc:name>
              <oc:file-parent>\(containerFileID)</oc:file-parent>
              <d:resourcetype/><d:getetag>"e1"</d:getetag><d:getcontentlength>10</d:getcontentlength></d:prop>
            <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
          <d:response><d:href>/dav/spaces/drive-1%24space-1/b.txt</d:href>
            <d:propstat><d:prop><oc:id>\(Self.ocisDrive)!c2</oc:id><oc:name>b.txt</oc:name>
              <oc:file-parent>\(containerFileID)</oc:file-parent>
              <d:resourcetype/><d:getetag>"e2"</d:getetag><d:getcontentlength>20</d:getcontentlength></d:prop>
            <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        </d:multistatus>
        """.utf8)
    }

    private func ocisSource(
        containerPath: String,
        containerFileID: String?,
        body: Data,
        status: Int = 207,
        capture: ((URLRequest) -> Void)? = nil
    ) -> OCISWebDAVEnumerationSource {
        OCISWebDAVEnumerationSource(
            client: client(status: status, body: body, capture: capture),
            // The base is the `/dav/spaces` collection: ids are single segments
            // under it, so the container path already carries the drive id.
            builder: WebDAVRequestBuilder(filesBaseURL: URL(string: "https://ocis.test/dav/spaces")!),
            containerPath: containerPath,
            containerFileID: containerFileID,
            driveID: Self.ocisDrive,
            authorization: "Bearer xyz"
        )
    }

    func testOCISSourcePropfindsTheSpaceRootAndMapsChildren() async throws {
        var seen: URLRequest?
        let source = ocisSource(
            containerPath: "/\(Self.ocisDrive)",
            containerFileID: nil,
            body: ocisBody(containerFileID: Self.ocisRootFileID),
            capture: { seen = $0 })

        let page = try await source.fetchPage(cursor: nil)

        XCTAssertEqual(seen?.httpMethod, "PROPFIND")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Depth"), "1")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Bearer xyz")
        XCTAssertEqual(page.items.map(\.filename), ["a.txt", "b.txt"])
        XCTAssertEqual(page.items.first?.identifier, ItemIdentifier(rawValue: "\(Self.ocisDrive)!c1"))
    }

    func testOCISSourceSynthesizesAnAnchorAndHasASinglePage() async throws {
        // No delta token over space WebDAV, exactly as Classic: one page, and an
        // anchor synthesized from the listing so enumerateChanges can re-list.
        let source = ocisSource(
            containerPath: "/\(Self.ocisDrive)",
            containerFileID: nil,
            body: ocisBody(containerFileID: Self.ocisRootFileID))

        let page = try await source.fetchPage(cursor: nil)

        XCTAssertNil(page.nextCursor)
        XCTAssertEqual(page.anchor, SyncAnchor(listing: page.items))
    }

    func testOCISSourceDropsTheSubfolderSelfEntry() async throws {
        let folderID = "\(Self.ocisDrive)!folder-1"
        let source = ocisSource(
            containerPath: "/\(folderID)",
            containerFileID: folderID,
            body: ocisBody(containerFileID: folderID))

        let page = try await source.fetchPage(cursor: nil)

        XCTAssertEqual(page.items.map(\.filename), ["a.txt", "b.txt"])
        XCTAssertFalse(page.items.contains { $0.identifier == ItemIdentifier(rawValue: folderID) })
        XCTAssertEqual(page.items.first?.parentIdentifier, ItemIdentifier(rawValue: folderID))
    }

    func testOCISSourceThrowsClassifiedErrorOnFailureStatus() async {
        let source = ocisSource(
            containerPath: "/\(Self.ocisDrive)", containerFileID: nil, body: Data(), status: 401)
        do {
            _ = try await source.fetchPage(cursor: nil)
            XCTFail("expected a thrown error")
        } catch let error as RemoteError {
            XCTAssertEqual(error, .authenticationRequired)
        } catch {
            XCTFail("expected RemoteError, got \(error)")
        }
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
