import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The transport seam every remote operation builds on (progress.md Phase 4).
/// It turns a backend-agnostic ``RemoteRequest`` into an HTTP round-trip via
/// ``URLRequestFactory``, attaches the `Authorization` header, and translates the
/// response: 2xx yields the body bytes, any other status throws the classified
/// ``RemoteError``. A transport-level failure (offline, TLS) propagates unchanged.
///
/// The actual network call is injected as `perform`, so the request-shaping and
/// response-classification logic is tested without a live server and the type
/// stays Linux-buildable. Production wiring passes a `URLSession`-backed
/// performer.
public struct RemoteClient {

    /// Executes a fully-formed `URLRequest`, returning the body and HTTP response.
    public typealias Perform = (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let perform: Perform

    public init(perform: @escaping Perform) {
        self.perform = perform
    }

    /// Send `request`, returning the response body on success or throwing a
    /// ``RemoteError`` classified from the status on an HTTP failure.
    @discardableResult
    public func send(_ request: RemoteRequest, authorization: String?) async throws -> Data {
        try await send(request, body: nil, authorization: authorization)
    }

    /// As ``send(_:authorization:)`` but with an explicit request body — the bytes
    /// of a content upload (WebDAV `PUT`, Graph `PUT /content`), which the pure
    /// ``RemoteRequest`` deliberately does not carry (it only records `hasBody`).
    /// A `nil` body falls back to the request's own `jsonBody`.
    @discardableResult
    public func send(_ request: RemoteRequest, body: Data?, authorization: String?) async throws -> Data {
        var urlRequest = try URLRequestFactory.urlRequest(from: request, authorization: authorization)
        if let body { urlRequest.httpBody = body }
        let (data, response) = try await perform(urlRequest)
        if let error = RemoteError(statusCode: response.statusCode) {
            throw error
        }
        return data
    }
}

public extension RemoteClient {
    /// A `URLSession`-backed performer for production use. Kept out of the
    /// initializer so tests inject a stub instead.
    static func urlSession(_ session: URLSession = .shared) -> RemoteClient {
        RemoteClient { urlRequest in
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            return (data, http)
        }
    }
}
