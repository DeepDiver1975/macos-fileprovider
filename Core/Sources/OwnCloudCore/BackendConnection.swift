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
            return GraphEnumerationSource(
                client: client,
                builder: graphBuilder,
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

    /// Graph content fetch (oCIS): a GET on `/items/{id}/content`.
    public func fetchContentsRequest(itemID: String) -> RemoteRequest {
        graphBuilder.fetchContents(driveID: driveID ?? "", itemID: itemID)
    }
}
