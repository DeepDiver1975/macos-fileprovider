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

    /// PROPFIND `Depth: 1` to list the immediate children of the container at
    /// `path` (Phase 3 enumeration). The request body asks for exactly the
    /// properties `WebDAVMultiStatusParser` reads back — requesting fewer would
    /// leave the parsed item incomplete, requesting more just wastes bytes.
    public func enumerate(path: String) -> RemoteRequest {
        RemoteRequest(
            method: .propfind,
            url: url(for: path),
            headers: ["Depth": "1", "Content-Type": "application/xml"],
            hasBody: true,
            jsonBody: Data(Self.propfindBody.utf8)
        )
    }

    /// PROPFIND `Depth: 0` for a single item's metadata (Phase 4 create
    /// read-back). Classic returns no metadata body on a `PUT`/`MKCOL`, so
    /// `createItem` reads the newly created item back with this to learn its
    /// server-assigned etag/size. Depth:0 returns just the item at `path`, not
    /// its children; the body asks for the same props as `enumerate`.
    public func properties(path: String) -> RemoteRequest {
        RemoteRequest(
            method: .propfind,
            url: url(for: path),
            headers: ["Depth": "0", "Content-Type": "application/xml"],
            hasBody: true,
            jsonBody: Data(Self.propfindBody.utf8)
        )
    }

    /// The `PROPFIND` request body. Namespaced props mirror the parser's
    /// `(namespace, localName)` switch: DAV core plus the ownCloud extension
    /// props (`oc:id`, `oc:size`, `oc:permissions`, `oc:favorite`).
    static let propfindBody = """
    <?xml version="1.0" encoding="UTF-8"?>
    <d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:prop>
        <d:resourcetype/>
        <d:getetag/>
        <d:getcontentlength/>
        <d:getcontenttype/>
        <d:getlastmodified/>
        <oc:id/>
        <oc:size/>
        <oc:permissions/>
        <oc:favorite/>
      </d:prop>
    </d:propfind>
    """
}
