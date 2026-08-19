import Foundation

/// Builds the one oCIS Graph request this project makes: listing the signed-in
/// user's drives. Pure request shaping — no networking.
///
/// **Graph's sole role is space discovery.** All file and folder I/O goes over each
/// space's own WebDAV endpoint instead (see ``SpaceWebDAVEndpoint``), because oCIS
/// 8.2.0 does not serve the Graph content endpoints this builder used to emit:
/// `PUT …/drives/{drive}/root:/{name}:/content` and its item-addressed variant
/// both 404, as did `GET …/root/children`, while the same operations over
/// `/dav/spaces` all succeed. The Graph enumerate/fetch/modify/delete/move/create
/// methods were removed rather than left in place, since several were proven not to
/// work and would mislead the next reader (Task 4.5).
///
/// `owncloud/client` is arranged the same way: its entire Graph layer is a single
/// drives job (`src/libsync/graphapi/jobs/drives.cpp`), and `Space::webDavUrl()`
/// hands the per-space URL to the same WebDAV jobs ownCloud Classic uses.
public struct GraphRequestBuilder {

    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// List the signed-in user's drives (`GET /me/drives`) — used at sign-in to
    /// resolve which drive the domain maps to (the personal drive), and the source
    /// of each space's `root.webDavUrl`.
    public func listDrives() -> RemoteRequest {
        let url = URL(string: baseURL.absoluteString + "/graph/v1.0/me/drives") ?? baseURL
        return RemoteRequest(method: .get, url: url)
    }
}
