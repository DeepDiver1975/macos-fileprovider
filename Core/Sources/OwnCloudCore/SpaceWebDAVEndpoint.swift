import Foundation

/// Addressing for an oCIS space's own WebDAV endpoint — the route all oCIS file
/// and folder I/O goes through (Task 4.5).
///
/// **Why WebDAV and not Graph.** oCIS 8.2.0 does not serve the Graph content
/// endpoints this project originally targeted: `PUT …/drives/{drive}/root:/{name}:/content`
/// and its item-addressed variant both 404, as did `GET …/root/children` (worked
/// around separately). The same operations against `/dav/spaces/{driveID}` all
/// succeed — PROPFIND 207, MKCOL/PUT/MOVE 201, GET 200, DELETE 204 — so Graph is
/// used only to *discover* spaces (`me/drives`) and everything else runs over
/// WebDAV, reusing the ownCloud Classic machinery. `owncloud/client` is built the
/// same way: its whole Graph layer is one drives job, and `Space::webDavUrl()`
/// feeds the same PROPFIND/PUT/MKCOL/MOVE/DELETE jobs Classic uses.
///
/// **Addressing is by id, not by path.** Unlike Classic, oCIS accepts any
/// `oc:fileid` directly as `/dav/spaces/{fileID}`, and a fileid survives both a
/// rename and a reparent. So oCIS item identifiers stay stable ids and never go
/// stale — the weakness Classic's path identifiers carry (see the comment on
/// ``FileProviderItemDescription/init(webDAVItem:parentIdentifier:)``). Only
/// *creating* an item is name-based, under its id-addressed parent.
///
/// **`/dav/spaces` is the id collection, and an id is always its *first*
/// segment.** A drive id addresses the space root and a fileid addresses an item,
/// but they are *siblings* under `/dav/spaces` — a fileid already begins with the
/// drive id, so it does not nest beneath it. Verified live, which is what fixes
/// the shape (both requests well-formed, same item):
///
/// | Request | Status |
/// |---|---|
/// | `PROPFIND /dav/spaces/{fileID}` | **207** |
/// | `PROPFIND /dav/spaces/{driveID}/{fileID}` | **404** |
///
/// So the base URL below is the `/dav/spaces` collection, *not* the per-space
/// `/dav/spaces/{driveID}`. This is the one place the arrangement departs from
/// `owncloud/client`, which uses `Space::webDavUrl()` as a base and addresses
/// items beneath it **by path**; addressing by id needs the parent collection.
public enum SpaceWebDAVEndpoint {

    /// The base URL every oCIS address hangs off: the `/dav/spaces` collection on
    /// `serverURL`, under which each id — drive id or fileid — is one segment.
    ///
    /// `me/drives` reports per drive a `root.webDavUrl` of
    /// `{server}/dav/spaces/{driveID}`; pass it as `reportedWebDavURL` and its
    /// *parent* collection is used, so a server that serves DAV from a different
    /// host or prefix than `serverURL` is still honoured. The derivation is the
    /// fallback for callers that hold only a drive id — notably the extension,
    /// which reconstructs `driveID` from the domain identifier and so needs no
    /// extra persisted state.
    ///
    /// Ids are inserted verbatim by ``path(for:driveID:)``: they contain `$` and
    /// `!`, and ``WebDAVRequestBuilder`` percent-encodes each segment when it
    /// appends the address. oCIS accepts the escaped form (verified live: 207).
    public static func baseURL(
        serverURL: URL,
        driveID: String,
        reportedWebDavURL: String? = nil
    ) -> URL {
        if let reportedWebDavURL,
           let reported = URL(string: reportedWebDavURL),
           reported.scheme != nil {
            // Strip the trailing drive-id segment to get back to the collection.
            // Only when it really is the drive id, so an unexpected shape falls
            // through to the derivation rather than losing a real path component.
            let text = reported.absoluteString
            let suffix = "/" + driveID
            if !driveID.isEmpty, text.hasSuffix(suffix) {
                return URL(string: String(text.dropLast(suffix.count))) ?? reported
            }
            return reported
        }
        let base = serverURL.absoluteString
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URL(string: trimmed + "/dav/spaces") ?? serverURL
    }

    /// The path, relative to ``baseURL(serverURL:driveID:reportedWebDavURL:)``,
    /// that addresses `container`: the space root addresses as the **drive id**,
    /// any other container as its own fileid. Both are a single segment — see the
    /// type comment for why a fileid does not nest under the drive id.
    public static func path(for container: ItemIdentifier, driveID: String) -> String {
        "/" + (container == .rootContainer ? driveID : container.rawValue)
    }

    /// Whether `fileID` denotes the root of the space `driveID`.
    ///
    /// Two forms mean "the space root", and both genuinely occur:
    ///
    /// - the **bare** `driveID` — what Graph reports as `root.id`, and what live
    ///   oCIS returns as the space root's *own* `oc:file-parent`;
    /// - `{driveID}!{spaceID}` — the root's `oc:id` over WebDAV. A driveID is
    ///   `{storageID}${spaceID}`, and the `!` suffix repeats the post-`$` segment.
    ///   This is the form a **top-level child** carries in `oc:file-parent`, so
    ///   comparing against only the bare driveID would leave every top-level item
    ///   parented to an unknown container.
    ///
    /// Verified live on two spaces of different types, which is what pins the rule
    /// down (the suffix is not documented, so it is asserted rather than assumed —
    /// see the contract test in `BackendContractTests`):
    ///
    /// | driveType | driveID | root `oc:id` |
    /// |---|---|---|
    /// | personal | `e876…$9c566819-…` | `e876…$9c566819-…!9c566819-…` |
    /// | virtual  | `a0ca…$a0ca6a90-…` | `a0ca…$a0ca6a90-…!a0ca6a90-…` |
    ///
    /// A child's suffix is its own UUID, so it does not match and is correctly
    /// rejected. Any other suffix is rejected too: accepting `{driveID}!…`
    /// wholesale would collapse every item in the space onto the root.
    public static func isRoot(fileID: String, driveID: String) -> Bool {
        if fileID == driveID { return true }
        guard let spaceID = driveID.split(separator: "$").last else { return false }
        return fileID == "\(driveID)!\(spaceID)"
    }

    /// The identifier to report for an item whose `oc:id` is `fileID`, normalising
    /// the space root onto ``ItemIdentifier/rootContainer`` — the value the
    /// FileProvider framework expects for a domain's root.
    public static func identifier(forFileID fileID: String, driveID: String) -> ItemIdentifier {
        isRoot(fileID: fileID, driveID: driveID) ? .rootContainer : ItemIdentifier(rawValue: fileID)
    }
}
