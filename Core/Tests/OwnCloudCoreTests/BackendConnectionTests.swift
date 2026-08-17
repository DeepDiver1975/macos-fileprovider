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

    // MARK: Graph (oCIS) — ID-addressed

    func testOCISRootEnumerationTargetsTheDriveChildren() async throws {
        var seen: URLRequest?
        let account = AccountDescriptor(backend: .ocis, serverURL: URL(string: "https://ocis.test")!, username: "einstein")
        let body = Data("""
        { "value": [ { "id": "1", "name": "a.txt", "size": 3, "eTag": "e", "file": { "mimeType": "text/plain" } } ] }
        """.utf8)
        // The drive id is provided when the connection is built (sign-in resolved it).
        let connection = BackendConnection(account: account, client: client(status: 200, body: body, capture: { seen = $0 }), authorization: "Bearer t", driveID: "drive-1")

        let source = connection.enumerationSource(for: .rootContainer)
        let page = try await source.fetchPage(cursor: nil)

        XCTAssertEqual(seen?.url?.absoluteString, "https://ocis.test/graph/v1.0/drives/drive-1/root/children")
        XCTAssertEqual(page.items.map(\.filename), ["a.txt"])
    }

    func testOCISFetchContentsTargetsTheItemContentEndpoint() {
        let account = AccountDescriptor(backend: .ocis, serverURL: URL(string: "https://ocis.test")!, username: "einstein")
        let connection = BackendConnection(account: account, client: client(status: 200, body: Data()), authorization: nil, driveID: "drive-1")

        let request = connection.fetchContentsRequest(itemID: "item-9")

        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.url.absoluteString, "https://ocis.test/graph/v1.0/drives/drive-1/items/item-9/content")
    }
}
