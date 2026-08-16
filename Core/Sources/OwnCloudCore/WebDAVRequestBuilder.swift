import Foundation

/// Builds WebDAV requests for ownCloud Classic content operations (Phase 4).
/// Pure request shaping — no networking — so it is fully unit-testable.
public struct WebDAVRequestBuilder {

    /// The per-user files root, e.g.
    /// `https://cloud.test/remote.php/dav/files/admin`.
    public let filesBaseURL: URL

    public init(filesBaseURL: URL) {
        self.filesBaseURL = filesBaseURL
    }

    /// Absolute URL for an item at `path` (relative to `filesBaseURL`), with each
    /// path segment percent-encoded.
    private func url(for path: String) -> URL {
        let encoded = PathEncoding.encode(path)
        let base = filesBaseURL.absoluteString
        let joined = base + (encoded.hasPrefix("/") ? encoded : "/" + encoded)
        return URL(string: joined) ?? filesBaseURL
    }

    public func fetchContents(path: String) -> RemoteRequest {
        RemoteRequest(method: .get, url: url(for: path))
    }

    public func createFile(path: String) -> RemoteRequest {
        RemoteRequest(method: .put, url: url(for: path), hasBody: true)
    }

    public func createDirectory(path: String) -> RemoteRequest {
        RemoteRequest(method: .mkcol, url: url(for: path))
    }

    public func modifyContents(path: String, ifMatchETag etag: String?) -> RemoteRequest {
        var headers: [String: String] = [:]
        if let etag { headers["If-Match"] = etag }
        return RemoteRequest(method: .put, url: url(for: path), headers: headers, hasBody: true)
    }

    public func delete(path: String) -> RemoteRequest {
        RemoteRequest(method: .delete, url: url(for: path))
    }

    /// MOVE with an absolute `Destination` header. `Overwrite: F` so a move never
    /// silently clobbers an existing item (the extension resolves conflicts).
    public func move(fromPath: String, toPath: String) -> RemoteRequest {
        let headers = [
            "Destination": url(for: toPath).absoluteString,
            "Overwrite": "F",
        ]
        return RemoteRequest(method: .move, url: url(for: fromPath), headers: headers)
    }
}
