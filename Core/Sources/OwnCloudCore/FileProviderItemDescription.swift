import Foundation

/// A stable item identifier, backend-agnostic. In the extension this maps to
/// `NSFileProviderItemIdentifier`; the reserved root value maps to
/// `.rootContainer`. Kept in the core so identifier construction is testable
/// without the FileProvider framework.
public struct ItemIdentifier: Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// The domain root. Mirrors `NSFileProviderItemIdentifier.rootContainer`,
    /// whose documented raw value is `NSFileProviderRootContainerItemIdentifier`.
    public static let rootContainer = ItemIdentifier(rawValue: "NSFileProviderRootContainerItemIdentifier")
}

/// The subset of `NSFileProviderItemCapabilities` the mappers decide. In the
/// extension these translate 1:1 to the framework option set.
public struct ItemCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let allowsReading   = ItemCapabilities(rawValue: 1 << 0)
    public static let allowsWriting   = ItemCapabilities(rawValue: 1 << 1)
    public static let allowsRenaming  = ItemCapabilities(rawValue: 1 << 2)
    public static let allowsDeleting  = ItemCapabilities(rawValue: 1 << 3)

    public static let readOnly: ItemCapabilities = [.allowsReading]
    public static let readWrite: ItemCapabilities = [.allowsReading, .allowsWriting, .allowsRenaming, .allowsDeleting]
}

/// Backend-agnostic description of one item, carrying exactly the fields the
/// extension's thin `NSFileProviderItem` adapter needs. The FileProvider
/// framework stays out of the core (progress.md Phase 3 / AC-2 Linux tier); the
/// adapter is a Mac-only wrapper.
public struct FileProviderItemDescription: Equatable, Sendable {
    public let identifier: ItemIdentifier
    public let parentIdentifier: ItemIdentifier
    public let filename: String
    public let isDirectory: Bool
    public let size: Int?
    /// Maps to `NSFileProviderItem.itemVersion` content component — we use the
    /// server etag, which changes on every content/metadata change.
    public let versionIdentifier: String?
    public let contentType: String?
    public let contentModificationDate: Date?
    public let capabilities: ItemCapabilities

    public init(
        identifier: ItemIdentifier,
        parentIdentifier: ItemIdentifier,
        filename: String,
        isDirectory: Bool,
        size: Int? = nil,
        versionIdentifier: String? = nil,
        contentType: String? = nil,
        contentModificationDate: Date? = nil,
        capabilities: ItemCapabilities = .readWrite
    ) {
        self.identifier = identifier
        self.parentIdentifier = parentIdentifier
        self.filename = filename
        self.isDirectory = isDirectory
        self.size = size
        self.versionIdentifier = versionIdentifier
        self.contentType = contentType
        self.contentModificationDate = contentModificationDate
        self.capabilities = capabilities
    }

    /// The synthetic description for a domain's root container.
    public static func rootContainer(filename: String) -> FileProviderItemDescription {
        FileProviderItemDescription(
            identifier: .rootContainer,
            parentIdentifier: .rootContainer,
            filename: filename,
            isDirectory: true,
            capabilities: .readWrite
        )
    }
}

// MARK: - WebDAV mapping (ownCloud Classic)

public extension FileProviderItemDescription {
    /// Map a parsed `WebDAVItem` to a description. The parent identifier must be
    /// supplied by the enumerator (WebDAV hrefs don't carry a parent id; the
    /// enumerator knows the container it is listing).
    init(webDAVItem item: WebDAVItem, parentIdentifier: ItemIdentifier) {
        // oc:id is the stable identifier; fall back to the href when absent.
        let id = item.fileID ?? item.href
        self.init(
            identifier: ItemIdentifier(rawValue: id),
            parentIdentifier: parentIdentifier,
            filename: item.name,
            isDirectory: item.isDirectory,
            size: item.isDirectory ? item.ocSize : item.contentLength,
            versionIdentifier: item.etag,
            contentType: item.isDirectory ? nil : item.contentType,
            contentModificationDate: item.lastModified,
            capabilities: FileProviderItemDescription.capabilities(fromWebDAVPermissions: item.permissions)
        )
    }

    /// ownCloud `oc:permissions` letters → capabilities. `W` (write), `N`
    /// (rename via create-in-parent), `D` (delete). Absent permissions default
    /// to read-write (Classic without the property still allows edits).
    static func capabilities(fromWebDAVPermissions permissions: String?) -> ItemCapabilities {
        guard let permissions else { return .readWrite }
        var caps: ItemCapabilities = [.allowsReading]
        if permissions.contains("W") { caps.insert(.allowsWriting) }
        if permissions.contains("N") { caps.insert(.allowsRenaming) }
        if permissions.contains("D") { caps.insert(.allowsDeleting) }
        return caps
    }
}

// MARK: - Graph mapping (oCIS)

public extension FileProviderItemDescription {
    /// Map a Graph `driveItem`. The Graph item carries its own parent via
    /// `parentReference.id`; a missing parent means the drive root.
    init(graphItem item: GraphItem) {
        let parent = item.parentID.map { ItemIdentifier(rawValue: $0) } ?? .rootContainer
        self.init(
            identifier: ItemIdentifier(rawValue: item.id),
            parentIdentifier: parent,
            filename: item.name,
            isDirectory: item.isFolder,
            size: item.size,
            versionIdentifier: item.eTag,
            contentType: item.isFolder ? nil : item.mimeType,
            contentModificationDate: item.lastModified,
            capabilities: .readWrite
        )
    }
}
