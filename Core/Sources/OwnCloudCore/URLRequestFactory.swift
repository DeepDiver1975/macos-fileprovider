import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Builds a Foundation `URLRequest` from a backend-agnostic ``RemoteRequest``.
///
/// This is the seam between the pure request-shaping layer (the Phase 4 WebDAV /
/// Graph builders) and code that actually issues HTTP — the live backend-contract
/// tier (AC-2) and the Mac networking layer. Kept Foundation-only (plus
/// `FoundationNetworking` on Linux) so it stays in the Linux-buildable core.
public enum URLRequestFactory {

    /// Map `remote` onto a `URLRequest`, copying its headers and body and adding
    /// the `Authorization` header from `authorization` (unless the request
    /// already carries one, or `authorization` is `nil`).
    public static func urlRequest(from remote: RemoteRequest, authorization: String?) throws -> URLRequest {
        var request = URLRequest(url: remote.url)
        request.httpMethod = remote.method.rawValue

        for (field, value) in remote.headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        // Only inject the session's Authorization when the request has not set
        // its own — a builder may deliberately carry an explicit one.
        if let authorization, remote.headers["Authorization"] == nil {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }

        if let jsonBody = remote.jsonBody {
            request.httpBody = jsonBody
        }

        return request
    }
}
