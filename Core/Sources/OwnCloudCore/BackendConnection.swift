import Foundation

/// The per-domain composition root: given an ``AccountDescriptor`` and a
/// ``RemoteClient``, it hands the extension's handlers the pieces they need —
/// enumeration sources, content fetch requests — with the backend difference
/// encapsulated in one place (progress.md Phase 3–5).
///
/// Both backends speak WebDAV; the one structural difference is how an item is
/// addressed. ownCloud Classic is **path-addressed** (under
/// `remote.php/dav/files/{user}`), while oCIS is **ID-addressed** (under the
/// space's own `/dav/spaces/{driveID}`, items by `oc:id`). Everything above this
/// seam works in terms of ``ItemIdentifier`` and ``RemoteRequest`` and does not
/// care which backend is underneath.
///
/// oCIS uses Graph only to discover spaces (`me/drives`); all file and folder I/O
/// goes over the space WebDAV endpoint, reusing the Classic request builder
/// verbatim (Task 4.5). See ``SpaceWebDAVEndpoint`` for why — in short, oCIS
/// 8.2.0 404s on the Graph content endpoints and answers every WebDAV verb, and
/// `owncloud/client` is built the same way.
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

    /// The same WebDAV builder, rooted at oCIS's id-addressing collection
    /// (`/dav/spaces`) instead of the Classic per-user files root. The builder
    /// needs no change: only the base URL differs.
    private var spaceWebDAVBuilder: WebDAVRequestBuilder {
        WebDAVRequestBuilder(
            filesBaseURL: SpaceWebDAVEndpoint.baseURL(
                serverURL: account.serverURL,
                driveID: driveID ?? ""
            )
        )
    }

    /// Address `identifier` under `/dav/spaces`: the drive id for the space root,
    /// else the item's own `oc:id`.
    private func spacePath(for identifier: ItemIdentifier) -> String {
        SpaceWebDAVEndpoint.path(for: identifier, driveID: driveID ?? "")
    }

    /// Address a *new* item called `name` under the id-addressed `parent` — the one
    /// place a name is needed, since an item that does not exist yet has no `oc:id`.
    private func spaceChildPath(under parent: ItemIdentifier, name: String) -> String {
        spacePath(for: parent) + "/" + name
    }

    // MARK: Enumeration

    /// The enumeration source for a container — a `PROPFIND Depth:1` either way.
    /// For the root container this lists the backend's top level (the user's files
    /// root / the space root); for a subfolder the identifier carries the address:
    /// a server-relative path on Classic, an `oc:id` on oCIS.
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
            // The space root is the WebDAV base itself; a subfolder is addressed by
            // its own oc:id. Each item's parent comes from the server
            // (`oc:file-parent`), so no parent identifier is threaded through.
            return OCISWebDAVEnumerationSource(
                client: client,
                builder: spaceWebDAVBuilder,
                containerPath: spacePath(for: container),
                containerFileID: container == .rootContainer ? nil : container.rawValue,
                driveID: driveID ?? "",
                authorization: authorization
            )
        }
    }

    // MARK: Content fetch

    /// WebDAV content fetch (Classic): a GET at the item's server-relative path.
    public func fetchContentsRequest(path: String) -> RemoteRequest {
        webDAVBuilder.fetchContents(path: path)
    }

    /// Space WebDAV content fetch (oCIS): a GET at the item's `oc:id`.
    public func fetchContentsRequest(itemID: String) -> RemoteRequest {
        spaceWebDAVBuilder.fetchContents(path: spacePath(for: ItemIdentifier(rawValue: itemID)))
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

    // MARK: Push operations — oCIS (ID-addressed space WebDAV)

    /// Space WebDAV content modify (oCIS): a PUT at the item's `oc:id` with an
    /// optional `If-Match` etag.
    public func modifyContentsRequest(itemID: String, ifMatchETag etag: String?) -> RemoteRequest {
        spaceWebDAVBuilder.modifyContents(
            path: spacePath(for: ItemIdentifier(rawValue: itemID)),
            ifMatchETag: etag
        )
    }

    /// Space WebDAV delete (oCIS): DELETE at the item's `oc:id`.
    public func deleteRequest(itemID: String) -> RemoteRequest {
        spaceWebDAVBuilder.delete(path: spacePath(for: ItemIdentifier(rawValue: itemID)))
    }

    /// Space WebDAV single-item metadata (oCIS): a `Depth:0` PROPFIND at the item's
    /// `oc:id`. Because oCIS serves `oc:file-parent` and `oc:name`, this one request
    /// yields identifier, parent and name together — everything `item(for:)` needs,
    /// with no href parsing. Also the read-back after a write (see
    /// ``readBackItem(fromOCISPropfind:)``).
    public func itemMetadataRequest(itemID: String) -> RemoteRequest {
        spaceWebDAVBuilder.properties(path: spacePath(for: ItemIdentifier(rawValue: itemID)))
    }

    /// Space WebDAV move/rename (oCIS): MOVE the item addressed by `oc:id` to a
    /// `Destination` formed from the new parent's `oc:id` and the new name. A `nil`
    /// `newParentID` means "same container" (a pure rename).
    ///
    /// The Classic builder is reused unchanged — verified live on oCIS: MOVE by id
    /// with an absolute `Destination` returns 201, the `oc:id` is unchanged
    /// afterwards (across both rename and reparent), and `Overwrite: F` correctly
    /// answers 412 on a collision.
    public func moveRequest(itemID: String, newName: String, newParentID: String?) -> RemoteRequest {
        let parent = newParentID.map { ItemIdentifier(rawValue: $0) } ?? .rootContainer
        return spaceWebDAVBuilder.move(
            fromPath: spacePath(for: ItemIdentifier(rawValue: itemID)),
            toPath: spaceChildPath(under: parent, name: newName)
        )
    }

    /// Space WebDAV create (oCIS): `MKCOL` for a folder, `PUT` for a file, at
    /// `{parent oc:id}/{name}` — the space root being the base itself.
    ///
    /// Creation is the one name-based operation: a new item has no `oc:id` yet, so
    /// it is addressed under its id-addressed parent by name. Neither verb returns
    /// a body, so callers follow with ``itemMetadataRequest(itemID:)`` to learn the
    /// server-assigned id and etag — the same read-back shape as Classic.
    public func createItemRequest(parentID: ItemIdentifier, name: String, isDirectory: Bool) -> RemoteRequest {
        let path = spaceChildPath(under: parentID, name: name)
        return isDirectory
            ? spaceWebDAVBuilder.createDirectory(path: path)
            : spaceWebDAVBuilder.createFile(path: path)
    }

    /// Space WebDAV read-back for a *just-created* item (oCIS): a `Depth:0` PROPFIND
    /// at `{parent oc:id}/{name}` — the same address ``createItemRequest(parentID:name:isDirectory:)``
    /// wrote to.
    ///
    /// This is the one read-back addressed by name rather than by id: the server
    /// assigns the `oc:id`, so it is unknown until the item is read back. Every
    /// later operation on the item uses ``itemMetadataRequest(itemID:)``.
    public func readBackNewItemRequest(parentID: ItemIdentifier, name: String) -> RemoteRequest {
        spaceWebDAVBuilder.properties(path: spaceChildPath(under: parentID, name: name))
    }

    /// Parse the single item from an oCIS read-back PROPFIND body. Unlike the
    /// Classic counterpart no parent is passed in: oCIS reports it as
    /// `oc:file-parent`. Returns `nil` if the multi-status has no entry — e.g. the
    /// item vanished between the write and the read-back.
    public func readBackItem(fromOCISPropfind body: Data) throws -> FileProviderItemDescription? {
        let items = try WebDAVMultiStatusParser().parse(body)
        guard let item = items.first else { return nil }
        return FileProviderItemDescription(ocisWebDAVItem: item, driveID: driveID ?? "")
    }
}
