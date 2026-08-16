import Foundation

/// A single resource parsed from a WebDAV `PROPFIND` multi-status response
/// (ownCloud Classic / SabreDAV). Backend-agnostic domain model — it carries
/// what the File Provider layer needs to build an `NSFileProviderItem`, without
/// depending on the FileProvider framework (so it stays Linux-buildable; see
/// progress.md AC-2 backend-contract tier).
public struct WebDAVItem: Equatable, Sendable {
    /// The raw `<d:href>` as returned by the server (percent-encoded, and with a
    /// trailing slash for collections).
    public let href: String

    /// `true` when `<d:resourcetype>` contains `<d:collection/>`.
    public let isDirectory: Bool

    /// ownCloud's stable `oc:id` (`nil` on servers/props that omit it).
    public let fileID: String?

    /// `<d:getetag>`, including the surrounding quotes exactly as sent.
    public let etag: String?

    /// `<d:getcontentlength>` in bytes — files only; `nil` for collections.
    public let contentLength: Int?

    /// ownCloud's `oc:size` (recursive size for collections) in bytes.
    public let ocSize: Int?

    /// `<d:getcontenttype>` — files only.
    public let contentType: String?

    /// `<d:getlastmodified>` parsed from RFC 1123.
    public let lastModified: Date?

    /// ownCloud `oc:permissions` string (e.g. `RDNVCK`).
    public let permissions: String?

    /// `oc:favorite` == `1`.
    public let isFavorite: Bool

    public init(
        href: String,
        isDirectory: Bool,
        fileID: String? = nil,
        etag: String? = nil,
        contentLength: Int? = nil,
        ocSize: Int? = nil,
        contentType: String? = nil,
        lastModified: Date? = nil,
        permissions: String? = nil,
        isFavorite: Bool = false
    ) {
        self.href = href
        self.isDirectory = isDirectory
        self.fileID = fileID
        self.etag = etag
        self.contentLength = contentLength
        self.ocSize = ocSize
        self.contentType = contentType
        self.lastModified = lastModified
        self.permissions = permissions
        self.isFavorite = isFavorite
    }

    /// User-visible name: the last path segment of `href`, trailing slash
    /// removed and percent-decoding applied.
    public var name: String {
        var path = href
        if path.hasSuffix("/") {
            path.removeLast()
        }
        let lastSegment = path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        return lastSegment.removingPercentEncoding ?? lastSegment
    }
}
