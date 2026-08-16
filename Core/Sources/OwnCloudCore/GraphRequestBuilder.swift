import Foundation

/// Builds oCIS Graph requests for content operations (Phase 4). Pure request
/// shaping — no networking.
///
/// Graph drive-item ids (`driveID`, `itemID`) contain `$` and `!`, which are
/// legal in a path and are sent verbatim, matching how oCIS routes them.
public struct GraphRequestBuilder {

    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    private func itemURL(driveID: String, itemID: String, suffix: String = "") -> URL {
        let path = "/graph/v1.0/drives/\(driveID)/items/\(itemID)\(suffix)"
        return URL(string: baseURL.absoluteString + path) ?? baseURL
    }

    public func fetchContents(driveID: String, itemID: String) -> RemoteRequest {
        RemoteRequest(method: .get, url: itemURL(driveID: driveID, itemID: itemID, suffix: "/content"))
    }

    public func modifyContents(driveID: String, itemID: String, ifMatchETag etag: String?) -> RemoteRequest {
        var headers: [String: String] = [:]
        if let etag { headers["If-Match"] = etag }
        return RemoteRequest(
            method: .put,
            url: itemURL(driveID: driveID, itemID: itemID, suffix: "/content"),
            headers: headers,
            hasBody: true
        )
    }

    public func delete(driveID: String, itemID: String) -> RemoteRequest {
        RemoteRequest(method: .delete, url: itemURL(driveID: driveID, itemID: itemID))
    }

    /// List the drive root for enumeration (Phase 3). The first page is a plain
    /// `/root/children` GET; subsequent pages follow the opaque `$token` the
    /// server returned in `nextLink`/`deltaLink` (carried here as a ``PageCursor``)
    /// against the `/root/delta` endpoint, which also drives change tracking.
    public func enumerate(driveID: String, cursor: PageCursor?) -> RemoteRequest {
        let path: String
        if let cursor {
            path = "/graph/v1.0/drives/\(driveID)/root/delta?$token=\(cursor.rawValue)"
        } else {
            path = "/graph/v1.0/drives/\(driveID)/root/children"
        }
        let url = URL(string: baseURL.absoluteString + path) ?? baseURL
        return RemoteRequest(method: .get, url: url)
    }

    /// POST a folder driveItem to the parent's `/children` collection.
    public func createFolder(driveID: String, parentID: String, name: String) -> RemoteRequest {
        let body: [String: Any] = [
            "name": name,
            "folder": [String: String](),
            // Fail rather than silently rename if a sibling already exists.
            "@microsoft.graph.conflictBehavior": "fail",
        ]
        let json = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return RemoteRequest(
            method: .post,
            url: itemURL(driveID: driveID, itemID: parentID, suffix: "/children"),
            headers: ["Content-Type": "application/json"],
            hasBody: true,
            jsonBody: json
        )
    }
}
