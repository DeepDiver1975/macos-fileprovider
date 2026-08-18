import Foundation

/// One selectable sync target in the settings window's Spaces tab (Task 7.2).
///
/// For oCIS this is a Graph drive (space); for Classic there is a single implicit
/// space over the files root, whose `driveID` is `nil` (Classic domains are
/// path-addressed, so they carry no drive id).
public struct Space: Sendable, Equatable {
    public let driveID: String?
    public let name: String
    public let driveType: String?
    public let quotaTotal: Int?
    public let quotaUsed: Int?

    public init(driveID: String?, name: String, driveType: String?, quotaTotal: Int?, quotaUsed: Int?) {
        self.driveID = driveID
        self.name = name
        self.driveType = driveType
        self.quotaTotal = quotaTotal
        self.quotaUsed = quotaUsed
    }

    /// The sync root selecting this space produces for `account` — the bridge from
    /// the catalog to the domain lifecycle (Task 7.4/7.5). `nil` if the drive id
    /// carries the reserved `|` separator (never true for oCIS ids).
    public func syncRoot(for account: AccountDescriptor) -> SyncRoot? {
        SyncRoot(account: account, driveID: driveID)
    }
}

/// The set of spaces an account can sync (Task 7.2). Built from a Graph
/// `me/drives` listing for oCIS, or the single files root for Classic.
public struct SpaceCatalog: Sendable, Equatable {
    public let spaces: [Space]

    public init(spaces: [Space]) {
        self.spaces = spaces
    }

    /// Map a Graph drive list to a catalog, preserving order.
    public init(drives: [GraphDrive]) {
        self.spaces = drives.map { drive in
            Space(
                driveID: drive.id,
                name: drive.name,
                driveType: drive.driveType,
                quotaTotal: drive.quota?.total,
                quotaUsed: drive.quota?.used
            )
        }
    }

    /// Classic's catalog: a single non-editable "All files" space with no drive id.
    public static let classic = SpaceCatalog(spaces: [
        Space(driveID: nil, name: "All files", driveType: nil, quotaTotal: nil, quotaUsed: nil)
    ])
}
