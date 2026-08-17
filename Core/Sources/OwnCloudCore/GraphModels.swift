import Foundation

/// oCIS / Microsoft Graph domain models. Backend-agnostic and Foundation-only
/// so the Graph client stays Linux-buildable for the AC-2 backend-contract tier.

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
    public let webDavUrl: String?
}

/// A Graph `driveItem` (file or folder) reduced to what the provider needs.
public struct GraphItem: Equatable, Sendable {
    public let id: String
    public let name: String
    public let size: Int?
    public let eTag: String?
    public let lastModified: Date?
    public let isFolder: Bool
    public let childCount: Int?
    public let mimeType: String?
    public let parentDriveID: String?
    public let parentID: String?
    /// `true` when the item carries a `deleted` facet (delta responses).
    public let isDeleted: Bool
}

/// A page of items plus the sync/paging tokens a delta response carries.
public struct GraphItemCollection: Equatable, Sendable {
    public let items: [GraphItem]
    /// `$token` extracted from `@odata.deltaLink` — the next delta sync anchor.
    public let deltaToken: String?
    /// `$token` extracted from `@odata.nextLink` — the next page within one enumeration.
    public let nextToken: String?
}
