import Foundation

/// The per-domain composition root: given an ``AccountDescriptor`` and a
/// ``RemoteClient``, it hands the extension's handlers the pieces they need —
/// enumeration sources, content fetch requests — with the backend difference
/// encapsulated in one place (progress.md Phase 3–5).
///
/// The one structural difference between the backends: ownCloud Classic is
/// **path-addressed** (WebDAV under `remote.php/dav/files/{user}`), while oCIS is
/// **ID-addressed** (Graph under `drives/{driveID}`, items by id). Everything
/// above this seam works in terms of ``ItemIdentifier`` and ``RemoteRequest`` and
/// does not care which backend is underneath.
public struct BackendConnection {

    public let account: AccountDescriptor
    private let client: RemoteClient
    private let authorization: String?
    /// The oCIS drive the domain maps to, resolved at sign-in. Unused for Classic.
    private let driveID: String?

    public init(account: AccountDescriptor, client: RemoteClient, authorization: String?, driveID: String? = nil) {
        self.account = account
        self.client = client
        self.authorization = authorization
        self.driveID = driveID
    }

    // MARK: Backend endpoints

    /// The per-user WebDAV files root, e.g.
    /// `https://cloud.test/remote.php/dav/files/admin`.
    private var webDAVFilesBaseURL: URL {
        account.serverURL.appendingPathComponent("remote.php/dav/files/\(account.username)")
    }

    private var webDAVBuilder: WebDAVRequestBuilder {
        WebDAVRequestBuilder(filesBaseURL: webDAVFilesBaseURL)
    }

    private var graphBuilder: GraphRequestBuilder {
        GraphRequestBuilder(baseURL: account.serverURL)
    }

    // MARK: Enumeration

    /// The enumeration source for a container. For the root container this lists
    /// the backend's top level (WebDAV files root / Graph drive children); for a
    /// subfolder the identifier carries the address (a path for WebDAV, an item id
    /// for Graph — Graph subfolder enumeration is added with the item-lookup work).
    public func enumerationSource(for container: ItemIdentifier) -> RemoteEnumerationSource {
        switch account.backend {
        case .classic:
            // WebDAV: the root container is the user's files root; a subfolder's
            // identifier is its server-relative path.
            let path = container == .rootContainer ? "/" : container.rawValue
            let href = webDAVFilesBaseURL.path + (path == "/" ? "/" : path)
            return WebDAVEnumerationSource(
                client: client,
                builder: webDAVBuilder,
                containerPath: path,
                containerHref: href,
                parentIdentifier: container,
                authorization: authorization
            )
        case .ocis:
            // Graph is item-addressed: the root container is the drive's root item
            // (id == driveID); a subfolder's identifier is its own item id.
            let drive = driveID ?? ""
            let itemID = container == .rootContainer ? drive : container.rawValue
            return GraphEnumerationSource(
                client: client,
                builder: graphBuilder,
                driveID: drive,
                itemID: itemID,
                authorization: authorization
            )
        }
    }

    // MARK: Content fetch

    /// WebDAV content fetch (Classic): a GET at the item's server-relative path.
    public func fetchContentsRequest(path: String) -> RemoteRequest {
        webDAVBuilder.fetchContents(path: path)
    }

    /// Graph content fetch (oCIS): a GET on `/items/{id}/content`.
    public func fetchContentsRequest(itemID: String) -> RemoteRequest {
        graphBuilder.fetchContents(driveID: driveID ?? "", itemID: itemID)
    }

    // MARK: Push operations — Classic (path-addressed)

    /// WebDAV file create (Classic): a PUT at the item's server-relative path.
    public func createFileRequest(path: String) -> RemoteRequest {
        webDAVBuilder.createFile(path: path)
    }

    /// WebDAV directory create (Classic): MKCOL at the collection's path.
    public func createDirectoryRequest(path: String) -> RemoteRequest {
        webDAVBuilder.createDirectory(path: path)
    }

    /// WebDAV content modify (Classic): a PUT with an optional `If-Match` etag for
    /// optimistic concurrency.
    public func modifyContentsRequest(path: String, ifMatchETag etag: String?) -> RemoteRequest {
        webDAVBuilder.modifyContents(path: path, ifMatchETag: etag)
    }

    /// WebDAV delete (Classic): DELETE at the item's path.
    public func deleteRequest(path: String) -> RemoteRequest {
        webDAVBuilder.delete(path: path)
    }

    /// WebDAV move/rename (Classic): MOVE with a `Destination` header and
    /// `Overwrite: F` so it never clobbers an existing item.
    public func moveRequest(fromPath: String, toPath: String) -> RemoteRequest {
        webDAVBuilder.move(fromPath: fromPath, toPath: toPath)
    }

    /// WebDAV metadata read-back (Classic): a `Depth:0` PROPFIND at the item's
    /// path. `createItem`/`modifyItem` need this because a `PUT`/`MKCOL` returns
    /// no metadata body, so the server-assigned id and etag are only knowable by
    /// reading the item back.
    public func readBackRequest(path: String) -> RemoteRequest {
        webDAVBuilder.properties(path: path)
    }

    /// Parse the single item from a Classic read-back PROPFIND body into a
    /// description under `parentIdentifier` (WebDAV hrefs don't carry a parent,
    /// so the caller supplies it). Returns `nil` if the multi-status has no
    /// entry — e.g. the item vanished between the write and the read-back.
    public func readBackItem(
        fromPropfind body: Data,
        parentIdentifier: ItemIdentifier
    ) throws -> FileProviderItemDescription? {
        let items = try WebDAVMultiStatusParser().parse(body)
        guard let item = items.first else { return nil }
        return FileProviderItemDescription(webDAVItem: item, parentIdentifier: parentIdentifier)
    }

    // MARK: Push operations — oCIS (ID-addressed)

    /// Graph content modify (oCIS): a PUT on `/items/{id}/content` with an
    /// optional `If-Match` etag.
    public func modifyContentsRequest(itemID: String, ifMatchETag etag: String?) -> RemoteRequest {
        graphBuilder.modifyContents(driveID: driveID ?? "", itemID: itemID, ifMatchETag: etag)
    }

    /// Graph delete (oCIS): DELETE on `/items/{id}`.
    public func deleteRequest(itemID: String) -> RemoteRequest {
        graphBuilder.delete(driveID: driveID ?? "", itemID: itemID)
    }

    /// Graph single-item metadata (oCIS): GET on `/items/{id}` — the response is
    /// one driveItem, decoded via `GraphJSONDecoder.decodeItem` for `item(for:)`.
    public func itemMetadataRequest(itemID: String) -> RemoteRequest {
        graphBuilder.metadata(driveID: driveID ?? "", itemID: itemID)
    }

    /// Graph move/rename (oCIS): PATCH the item with a new name and, when moving
    /// to a different container, the new `parentReference.id`. The ID-addressed
    /// counterpart of Classic's ``moveRequest(fromPath:toPath:)``.
    public func moveRequest(itemID: String, newName: String, newParentID: String?) -> RemoteRequest {
        graphBuilder.move(driveID: driveID ?? "", itemID: itemID, newName: newName, newParentID: newParentID)
    }

    /// Graph folder create (oCIS): POST a folder driveItem to the parent's
    /// `/children` collection.
    public func createFolderRequest(parentID: String, name: String) -> RemoteRequest {
        graphBuilder.createFolder(driveID: driveID ?? "", parentID: parentID, name: name)
    }

    /// Graph new-file upload (oCIS): PUT the bytes under the parent addressed by
    /// name, returning the created driveItem for reconciliation.
    public func uploadNewFileRequest(parentID: String, name: String) -> RemoteRequest {
        graphBuilder.uploadNewFile(driveID: driveID ?? "", parentID: parentID, name: name)
    }

    /// Graph create (oCIS): shape the request for creating `name` under `parentID`,
    /// making the two routing decisions in one place — root vs. a specific parent
    /// (Graph addresses the drive root by its `root` segment, not `items/{id}`),
    /// and folder (POST `/children`) vs. file (PUT `:/name:/content`). The `.put`
    /// file request carries the bytes; the `.post` folder request carries JSON.
    public func createItemRequest(parentID: ItemIdentifier, name: String, isDirectory: Bool) -> RemoteRequest {
        let drive = driveID ?? ""
        let underRoot = parentID == .rootContainer
        switch (isDirectory, underRoot) {
        case (true, true):
            return graphBuilder.createFolderUnderRoot(driveID: drive, name: name)
        case (true, false):
            return graphBuilder.createFolder(driveID: drive, parentID: parentID.rawValue, name: name)
        case (false, true):
            return graphBuilder.uploadNewFileUnderRoot(driveID: drive, name: name)
        case (false, false):
            return graphBuilder.uploadNewFile(driveID: drive, parentID: parentID.rawValue, name: name)
        }
    }
}
