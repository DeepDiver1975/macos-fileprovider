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

    /// The drive root, addressed by the `root` segment rather than `items/{id}` —
    /// used for creating items in the top level of a drive.
    private func rootURL(driveID: String, suffix: String = "") -> URL {
        let path = "/graph/v1.0/drives/\(driveID)/root\(suffix)"
        return URL(string: baseURL.absoluteString + path) ?? baseURL
    }

    /// Percent-encode a filename for the `:/name:/` path syntax (unreserved set;
    /// spaces and reserved characters escape).
    private static func encode(name: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
    }

    /// List the signed-in user's drives (`GET /me/drives`) — used at sign-in to
    /// resolve which drive the domain maps to (the personal drive).
    public func listDrives() -> RemoteRequest {
        let url = URL(string: baseURL.absoluteString + "/graph/v1.0/me/drives") ?? baseURL
        return RemoteRequest(method: .get, url: url)
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

    /// Fetch a single driveItem's metadata (`GET /items/{id}`, no `/content`) —
    /// the response is one driveItem, decoded for `item(for:)` single-item lookup.
    public func metadata(driveID: String, itemID: String) -> RemoteRequest {
        RemoteRequest(method: .get, url: itemURL(driveID: driveID, itemID: itemID))
    }

    /// List a container's children for enumeration (Phase 3), addressed by the
    /// container's **item id** — `/items/{itemID}/children`. For the drive root the
    /// item id is the drive's root id, which oCIS reports equal to the driveID
    /// string. oCIS 8.2.0 does **not** implement the MS-Graph `/root/children`
    /// shortcut (it 404s even with valid auth — proven live), so enumeration is
    /// uniformly item-addressed; this also lets subfolders enumerate their own
    /// children rather than re-listing the root.
    ///
    /// Subsequent pages follow the opaque `$token` the server returned in
    /// `nextLink`/`deltaLink` (carried here as a ``PageCursor``) against the item's
    /// `/delta` endpoint, which also drives change tracking.
    public func enumerate(driveID: String, itemID: String, cursor: PageCursor?) -> RemoteRequest {
        let suffix = cursor.map { "/delta?$token=\($0.rawValue)" } ?? "/children"
        return RemoteRequest(method: .get, url: itemURL(driveID: driveID, itemID: itemID, suffix: suffix))
    }

    /// PUT a new file's bytes under its parent, addressed by name via the
    /// `items/{parent}:/{name}:/content` path syntax. The response is the created
    /// driveItem the extension decodes to reconcile the server-assigned id.
    public func uploadNewFile(driveID: String, parentID: String, name: String) -> RemoteRequest {
        let url = itemURL(driveID: driveID, itemID: parentID, suffix: ":/\(Self.encode(name: name)):/content")
        return RemoteRequest(method: .put, url: url, hasBody: true)
    }

    /// PUT a new file's bytes into the drive root, via the `root:/name:/content`
    /// syntax — the root-parent form of ``uploadNewFile(driveID:parentID:name:)``.
    public func uploadNewFileUnderRoot(driveID: String, name: String) -> RemoteRequest {
        let url = rootURL(driveID: driveID, suffix: ":/\(Self.encode(name: name)):/content")
        return RemoteRequest(method: .put, url: url, hasBody: true)
    }

    /// POST a folder driveItem to the parent's `/children` collection.
    public func createFolder(driveID: String, parentID: String, name: String) -> RemoteRequest {
        folderRequest(url: itemURL(driveID: driveID, itemID: parentID, suffix: "/children"), name: name)
    }

    /// POST a folder driveItem to the drive root's `/children` collection — the
    /// root-parent form of ``createFolder(driveID:parentID:name:)``.
    public func createFolderUnderRoot(driveID: String, name: String) -> RemoteRequest {
        folderRequest(url: rootURL(driveID: driveID, suffix: "/children"), name: name)
    }

    /// PATCH the item to rename and/or reparent it — the ID-addressed counterpart
    /// of WebDAV `MOVE`. `name` sets the new filename; `newParentID`, when given,
    /// moves the item under a different parent via `parentReference.id`. A pure
    /// rename omits `parentReference`.
    public func move(driveID: String, itemID: String, newName: String, newParentID: String?) -> RemoteRequest {
        var body: [String: Any] = ["name": newName]
        if let newParentID {
            body["parentReference"] = ["id": newParentID]
        }
        let json = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return RemoteRequest(
            method: .patch,
            url: itemURL(driveID: driveID, itemID: itemID),
            headers: ["Content-Type": "application/json"],
            hasBody: true,
            jsonBody: json
        )
    }

    private func folderRequest(url: URL, name: String) -> RemoteRequest {
        let body: [String: Any] = [
            "name": name,
            "folder": [String: String](),
            // Fail rather than silently rename if a sibling already exists.
            "@microsoft.graph.conflictBehavior": "fail",
        ]
        let json = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return RemoteRequest(
            method: .post,
            url: url,
            headers: ["Content-Type": "application/json"],
            hasBody: true,
            jsonBody: json
        )
    }
}
