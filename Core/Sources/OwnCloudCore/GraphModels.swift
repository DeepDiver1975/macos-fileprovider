import Foundation

/// oCIS / Microsoft Graph domain models. Backend-agnostic and Foundation-only
/// so the Graph client stays Linux-buildable for the AC-2 backend-contract tier.
///
/// Only *drive* (space) models live here. Graph's role is space discovery alone —
/// file and folder I/O runs over each space's WebDAV endpoint, so the `driveItem`
/// models this file used to carry were removed with the Graph file-operation layer
/// (Task 4.5; see ``GraphRequestBuilder`` for the 404 evidence). The WebDAV
/// counterpart is ``WebDAVItem``.

/// A Graph `drive` (an oCIS space: personal, project, virtual "Shares", …).
public struct GraphDrive: Equatable, Sendable {
    public let id: String
    public let name: String
    public let driveType: String?
    public let driveAlias: String?
    public let quota: GraphQuota?
    public let root: GraphDriveRoot?

    /// The user's personal drive from a `me/drives` listing — the one the domain
    /// maps to. oCIS tags it `driveType == "personal"`; `nil` if none is present.
    public static func personalDrive(in drives: [GraphDrive]) -> GraphDrive? {
        drives.first { $0.driveType == "personal" }
    }
}

public struct GraphQuota: Equatable, Sendable {
    public let total: Int?
    public let used: Int?
    public let remaining: Int?
    public let state: String?
}

public struct GraphDriveRoot: Equatable, Sendable {
    public let id: String?
    /// The space's own WebDAV endpoint, `{server}/dav/spaces/{driveID}` — the route
    /// all file and folder I/O for the space goes through. See
    /// ``SpaceWebDAVEndpoint/baseURL(serverURL:driveID:reportedWebDavURL:)``.
    public let webDavUrl: String?
}
