import XCTest
@testable import OwnCloudCore

/// Turns a backend-agnostic `RemoteRequest` into a Foundation `URLRequest`,
/// attaching the `Authorization` header. This is the seam between the pure
/// request-shaping layer (Phase 4 builders) and the live backend-contract tier
/// (AC-2). Kept Foundation-only so it builds on Linux.
final class URLRequestFactoryTests: XCTestCase {

    private let url = URL(string: "https://cloud.test/remote.php/dav/files/admin/report.pdf")!

    func testMapsMethodAndURL() throws {
        let remote = RemoteRequest(method: .propfind, url: url)
        let request = try URLRequestFactory.urlRequest(from: remote, authorization: "Basic abc")
        XCTAssertEqual(request.httpMethod, "PROPFIND")
        XCTAssertEqual(request.url, url)
    }

    func testAttachesAuthorizationHeader() throws {
        let remote = RemoteRequest(method: .get, url: url)
        let request = try URLRequestFactory.urlRequest(from: remote, authorization: "Bearer xyz")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer xyz")
    }

    func testCopiesRequestHeaders() throws {
        let remote = RemoteRequest(method: .move, url: url, headers: ["Destination": "https://cloud.test/x", "Overwrite": "F"])
        let request = try URLRequestFactory.urlRequest(from: remote, authorization: "Basic abc")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Destination"), "https://cloud.test/x")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Overwrite"), "F")
    }

    func testAttachesJSONBodyAndContentType() throws {
        let json = Data(#"{"name":"folder"}"#.utf8)
        let remote = RemoteRequest(method: .post, url: url, hasBody: true, jsonBody: json)
        let request = try URLRequestFactory.urlRequest(from: remote, authorization: "Basic abc")
        XCTAssertEqual(request.httpBody, json)
    }

    func testNoAuthorizationHeaderWhenNil() throws {
        let remote = RemoteRequest(method: .get, url: url)
        let request = try URLRequestFactory.urlRequest(from: remote, authorization: nil)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testExplicitHeaderIsNotOverwrittenByAuthorization() throws {
        // A request that already carries its own Authorization keeps it.
        let remote = RemoteRequest(method: .get, url: url, headers: ["Authorization": "Basic explicit"])
        let request = try URLRequestFactory.urlRequest(from: remote, authorization: "Basic injected")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic explicit")
    }
}
