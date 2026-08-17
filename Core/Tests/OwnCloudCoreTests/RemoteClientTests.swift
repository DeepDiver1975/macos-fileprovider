import XCTest
@testable import OwnCloudCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `RemoteClient` is the transport seam every Phase 4 operation builds on: it
/// turns a backend-agnostic `RemoteRequest` into an HTTP round-trip, attaches
/// the `Authorization` header, and translates the response into either the body
/// bytes (2xx) or a thrown ``RemoteError`` (classified failure). The actual
/// `URLSession` is injected as a performer closure so this is driven without a
/// live server and stays Linux-buildable.
final class RemoteClientTests: XCTestCase {

    private let request = RemoteRequest(
        method: .get,
        url: URL(string: "https://cloud.test/remote.php/dav/files/admin/a.txt")!
    )

    private func client(
        status: Int,
        body: Data = Data(),
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

    func testReturnsBodyOnSuccess() async throws {
        let payload = Data("hello".utf8)
        let data = try await client(status: 200, body: payload).send(request, authorization: nil)
        XCTAssertEqual(data, payload)
    }

    func testAttachesAuthorizationHeader() async throws {
        var seen: URLRequest?
        let client = client(status: 200, capture: { seen = $0 })
        _ = try await client.send(request, authorization: "Bearer xyz")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Bearer xyz")
    }

    func testThrowsClassifiedRemoteErrorOnFailureStatus() async {
        do {
            _ = try await client(status: 404).send(request, authorization: nil)
            XCTFail("expected a thrown error")
        } catch let error as RemoteError {
            XCTAssertEqual(error, .noSuchItem)
        } catch {
            XCTFail("expected RemoteError, got \(error)")
        }
    }

    func testThrowsVersionConflictOnPreconditionFailed() async {
        do {
            _ = try await client(status: 412).send(request, authorization: nil)
            XCTFail("expected a thrown error")
        } catch let error as RemoteError {
            XCTAssertEqual(error, .versionConflict)
        } catch {
            XCTFail("expected RemoteError, got \(error)")
        }
    }

    func testPropagatesTransportError() async {
        struct Offline: Error {}
        let client = RemoteClient { _ in throw Offline() }
        do {
            _ = try await client.send(request, authorization: nil)
            XCTFail("expected a thrown error")
        } catch is Offline {
            // expected — a transport failure propagates unchanged.
        } catch {
            XCTFail("expected Offline, got \(error)")
        }
    }
}
