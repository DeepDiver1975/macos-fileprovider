import Foundation

/// Decodes oCIS Graph API JSON bodies into the `Graph*` domain models.
///
/// Uses `Codable` intermediate wire types (`Wire*`) that mirror the Graph
/// `driveItem` shape, then flattens them to the provider-facing models. Kept
/// Foundation-only for the AC-2 backend-contract tier.
public struct GraphJSONDecoder {

    public init() {}

    // ISO 8601 with fractional-second tolerance (Graph sometimes emits them).
    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: string) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    public func decodeDriveList(_ data: Data) throws -> [GraphDrive] {
        let wire = try JSONDecoder().decode(WireCollection<WireDrive>.self, from: data)
        return wire.value.map { d in
            GraphDrive(
                id: d.id,
                name: d.name ?? "",
                driveType: d.driveType,
                driveAlias: d.driveAlias,
                quota: d.quota.map { GraphQuota(total: $0.total, used: $0.used, remaining: $0.remaining, state: $0.state) },
                root: d.root.map { GraphDriveRoot(id: $0.id, webDavUrl: $0.webDavUrl) }
            )
        }
    }

    public func decodeItemCollection(_ data: Data) throws -> GraphItemCollection {
        let wire = try JSONDecoder().decode(WireCollection<WireItem>.self, from: data)
        let items = wire.value.map { i in
            GraphItem(
                id: i.id,
                name: i.name ?? "",
                size: i.size,
                eTag: i.eTag,
                lastModified: Self.parseDate(i.lastModifiedDateTime),
                isFolder: i.folder != nil,
                childCount: i.folder?.childCount,
                mimeType: i.file?.mimeType,
                parentDriveID: i.parentReference?.driveId,
                parentID: i.parentReference?.id,
                isDeleted: i.deleted != nil
            )
        }
        return GraphItemCollection(
            items: items,
            deltaToken: Self.token(fromLink: wire.deltaLink),
            nextToken: Self.token(fromLink: wire.nextLink)
        )
    }

    /// Extracts the `$token` query value from an `@odata.deltaLink` / `nextLink`.
    private static func token(fromLink link: String?) -> String? {
        guard let link, let components = URLComponents(string: link) else { return nil }
        return components.queryItems?.first(where: { $0.name == "$token" })?.value
    }
}

// MARK: - Wire types (mirror the Graph JSON exactly)

private struct WireCollection<Element: Decodable>: Decodable {
    let value: [Element]
    let deltaLink: String?
    let nextLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case deltaLink = "@odata.deltaLink"
        case nextLink = "@odata.nextLink"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = try c.decodeIfPresent([Element].self, forKey: .value) ?? []
        deltaLink = try c.decodeIfPresent(String.self, forKey: .deltaLink)
        nextLink = try c.decodeIfPresent(String.self, forKey: .nextLink)
    }
}

private struct WireDrive: Decodable {
    let id: String
    let name: String?
    let driveType: String?
    let driveAlias: String?
    let quota: WireQuota?
    let root: WireDriveRoot?
}

private struct WireQuota: Decodable {
    let total: Int?
    let used: Int?
    let remaining: Int?
    let state: String?
}

private struct WireDriveRoot: Decodable {
    let id: String?
    let webDavUrl: String?
}

private struct WireItem: Decodable {
    let id: String
    let name: String?
    let size: Int?
    let eTag: String?
    let lastModifiedDateTime: String?
    let folder: WireFolderFacet?
    let file: WireFileFacet?
    let deleted: WireDeletedFacet?
    let parentReference: WireParentReference?
}

private struct WireFolderFacet: Decodable {
    let childCount: Int?
}

private struct WireFileFacet: Decodable {
    let mimeType: String?
}

private struct WireDeletedFacet: Decodable {
    let state: String?
}

private struct WireParentReference: Decodable {
    let driveId: String?
    let id: String?
}
