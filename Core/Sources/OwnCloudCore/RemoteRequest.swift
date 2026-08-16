import Foundation

/// HTTP methods used across the two backends, including the WebDAV verbs.
public enum HTTPMethod: String, Sendable, Equatable {
    case get = "GET"
    case put = "PUT"
    case post = "POST"
    case delete = "DELETE"
    case mkcol = "MKCOL"
    case move = "MOVE"
    case propfind = "PROPFIND"
}

/// A backend-agnostic description of one HTTP request. The Mac-only networking
/// layer turns this into a `URLRequest` and attaches the `Authorization` header
/// from `SessionManager`; the body (a file URL for uploads, or JSON) is provided
/// by the caller — here we only record whether a body is expected, so the pure
/// request-shaping logic is testable without real bytes.
public struct RemoteRequest: Equatable, Sendable {
    public let method: HTTPMethod
    public let url: URL
    public var headers: [String: String]
    /// `true` when this request carries a request body (upload PUT, JSON POST).
    public let hasBody: Bool
    /// JSON body bytes for metadata operations (folder create). `nil` for
    /// content uploads, whose body is a file streamed by the networking layer.
    public let jsonBody: Data?

    public init(
        method: HTTPMethod,
        url: URL,
        headers: [String: String] = [:],
        hasBody: Bool = false,
        jsonBody: Data? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.hasBody = hasBody
        self.jsonBody = jsonBody
    }
}

/// Percent-encoding helpers shared by the builders. Path segments are encoded
/// individually so that `/` separators survive but reserved characters within a
/// name (spaces, `#`, `?`, …) are escaped.
enum PathEncoding {
    /// Encode each non-empty segment of `path` and re-join with `/`, preserving a
    /// leading slash. `+` is encoded too — WebDAV servers otherwise read it as a
    /// space.
    static func encode(_ path: String) -> String {
        // A conservative set: unreserved per RFC 3986. Everything else escapes.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
        let encoded = segments.map { segment -> String in
            String(segment).addingPercentEncoding(withAllowedCharacters: allowed) ?? String(segment)
        }
        let joined = encoded.joined(separator: "/")
        return path.hasPrefix("/") ? "/" + joined : joined
    }
}
