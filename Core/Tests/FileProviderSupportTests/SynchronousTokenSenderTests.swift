import XCTest
@testable import FileProviderSupport
@testable import OwnCloudCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The transport that lets the File Provider extension renew an oCIS access token
/// (issue #17; the refresh half of Task 2.5).
///
/// `SessionManager.RefreshHandler` is deliberately synchronous — the refresh runs
/// under the exclusive `RefreshLock`, and a blocking round-trip is what serializes
/// N extension instances against one Keychain item. So the token POST needs a
/// synchronous transport, which is what this adapter is. Its seam is
/// completion-handler shaped (not `async`) on purpose: blocking a cooperative-pool
/// thread while awaiting a `Task` risks starving the pool that would deliver the
/// result.
final class SynchronousTokenSenderTests: XCTestCase {

    private let request = OIDCTokenRequestBuilder(
        tokenEndpoint: URL(string: "https://ocis.test/idp/token")!
    ).refresh(refreshToken: "r1", clientID: "client", clientSecret: "secret", scope: nil)

    private func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://ocis.test/idp/token")!,
                        statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    /// The happy path: the body comes back from a synchronous call, and the request
    /// actually sent is the shaped token POST (method, URL and form body intact).
    func testReturnsBodyAndSendsTheShapedRequest() throws {
        var sent: URLRequest?
        let sender = SynchronousTokenSender { urlRequest, completion in
            sent = urlRequest
            completion(Data(#"{"access_token":"a2"}"#.utf8), self.response(200), nil)
        }

        let data = try sender.send(request)

        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"access_token":"a2"}"#)
        XCTAssertEqual(sent?.httpMethod, "POST")
        XCTAssertEqual(sent?.url?.absoluteString, "https://ocis.test/idp/token")
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "Content-Type"),
                       "application/x-www-form-urlencoded")
        let body = String(decoding: sent?.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("grant_type=refresh_token"), body)
        XCTAssertTrue(body.contains("client_secret=secret"), body)
    }

    /// The load-bearing property: `send` blocks until the result arrives, even when
    /// it is delivered from another thread. Without this the handler would return
    /// before the token existed and `SessionManager` would persist nothing.
    func testBlocksUntilACompletionFromAnotherThreadArrives() throws {
        let sender = SynchronousTokenSender { _, completion in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                completion(Data(#"{"access_token":"late"}"#.utf8), self.response(200), nil)
            }
        }

        let data = try sender.send(request)

        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"access_token":"late"}"#)
    }

    /// A revoked or expired refresh token is answered with `400 invalid_grant`
    /// (RFC 6749 §5.2), not 401. It must still surface as *re-authenticate* so the
    /// extension's error path offers the reconnect deep link rather than looking
    /// like a transient server fault it should keep retrying.
    func testInvalidGrantSurfacesAsAuthenticationRequired() {
        let sender = SynchronousTokenSender { _, completion in
            completion(Data(#"{"error":"invalid_grant"}"#.utf8), self.response(400), nil)
        }

        XCTAssertThrowsError(try sender.send(request)) { error in
            XCTAssertEqual(error as? RemoteError, .authenticationRequired)
        }
    }

    func testUnauthorizedClientSurfacesAsAuthenticationRequired() {
        let sender = SynchronousTokenSender { _, completion in
            completion(Data(), self.response(401), nil)
        }

        XCTAssertThrowsError(try sender.send(request)) { error in
            XCTAssertEqual(error as? RemoteError, .authenticationRequired)
        }
    }

    /// A 5xx is transient: it must *not* read as "re-authenticate", or a server
    /// hiccup would prompt the user to sign in again.
    func testServerErrorStaysTransient() {
        let sender = SynchronousTokenSender { _, completion in
            completion(Data(), self.response(503), nil)
        }

        XCTAssertThrowsError(try sender.send(request)) { error in
            XCTAssertEqual(error as? RemoteError, .serverError)
        }
    }

    /// A transport failure (offline, TLS) propagates unchanged, matching
    /// `RemoteClient`'s posture.
    func testTransportErrorPropagates() {
        let sender = SynchronousTokenSender { _, completion in
            completion(nil, nil, URLError(.notConnectedToInternet))
        }

        XCTAssertThrowsError(try sender.send(request)) { error in
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }

    /// A completion that never arrives must not wedge the caller forever — it holds
    /// the cross-process refresh lock while it waits, so every other instance would
    /// block behind it.
    func testTimesOutRatherThanBlockingForever() {
        let sender = SynchronousTokenSender(timeout: 0.05) { _, _ in
            // Never completes.
        }

        XCTAssertThrowsError(try sender.send(request)) { error in
            XCTAssertEqual(error as? SynchronousTokenSenderError, .timedOut)
        }
    }

    /// A non-HTTP response has no status to classify, so it is a protocol error
    /// rather than a silently-accepted body.
    func testNonHTTPResponseIsRejected() {
        let sender = SynchronousTokenSender { _, completion in
            completion(Data(), nil, nil)
        }

        XCTAssertThrowsError(try sender.send(request)) { error in
            XCTAssertEqual(error as? SynchronousTokenSenderError, .invalidResponse)
        }
    }
}
