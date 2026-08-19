import Foundation

/// Decodes the one oCIS Graph JSON body this project reads: a `me/drives`
/// listing.
///
/// Uses `Codable` intermediate wire types (`Wire*`) that mirror the Graph `drive`
/// shape, then flattens them to the provider-facing models. Kept Foundation-only
/// for the AC-2 backend-contract tier. The `driveItem` decoders were removed with
/// the Graph file-operation layer (Task 4.5) — items now arrive as WebDAV
/// multi-status and are parsed by ``WebDAVMultiStatusParser``.
public struct GraphJSONDecoder {

    public init() {}

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

}

// MARK: - Wire types (mirror the Graph JSON exactly)

private struct WireCollection<Element: Decodable>: Decodable {
    let value: [Element]

    enum CodingKeys: String, CodingKey {
        case value
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = try c.decodeIfPresent([Element].self, forKey: .value) ?? []
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
