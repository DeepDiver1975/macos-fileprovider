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

    /// The framework's working set — its cross-tree feed of recents, favourites and
    /// materialised items. Mirrors `NSFileProviderItemIdentifier.workingSet`, whose
    /// documented raw value is `NSFileProviderWorkingSetContainerItemIdentifier`.
    ///
    /// Like ``rootContainer`` this is a *reserved* identifier, never a server id, so
    /// it must be recognised before an id-addressed URL is built from it — see
    /// ``enumerationContainer``.
    public static let workingSet = ItemIdentifier(rawValue: "NSFileProviderWorkingSetContainerItemIdentifier")

    /// The framework's trash. Mirrors `NSFileProviderItemIdentifier.trashContainer`,
    /// whose documented raw value is `NSFileProviderTrashContainerItemIdentifier`.
    /// Also reserved, and — unlike the other two — not something this provider can
    /// serve; see ``enumerationContainer``.
    public static let trashContainer = ItemIdentifier(rawValue: "NSFileProviderTrashContainerItemIdentifier")

    /// Whether this is one of the framework's reserved identifiers rather than a
    /// server id — so it must never reach a request builder as an address.
    public var isReserved: Bool {
        self == .rootContainer || self == .workingSet || self == .trashContainer
    }

    /// The container this identifier actually addresses, or `nil` if it cannot be
    /// served at all.
    ///
    /// The framework hands both `enumerator(for:)` and `item(for:)` three *reserved*
    /// identifiers alongside real item ids. Used verbatim as an address each names a
    /// container no server has: `PROPFIND /dav/spaces/NSFileProviderTrashContainerItemIdentifier`
    /// was observed 404ing live from *both* call sites, and the working-set URL 404s
    /// the same way. They resolve as follows:
    ///
    /// - ``rootContainer`` → itself. Callers answer it synthetically; there is no
    ///   backend round-trip, because no server serves a "root" name either.
    /// - ``workingSet`` → the root. It is a view over the whole tree (recents,
    ///   favourites, materialised items), so the root listing is an honest answer for
    ///   it. A full recursive walk would be a richer one; that is a separate concern.
    /// - ``trashContainer`` → `nil`. Neither backend exposes its trash through this
    ///   provider, and mapping it to the root would be actively wrong: Finder would
    ///   show every live file as trashed, and "Put Back" / "Empty Trash" would then
    ///   operate on them. Refusing is the truthful answer, and the framework's own
    ///   response to a provider that does not implement trash.
    ///
    /// Any other identifier is a real item id and is returned unchanged.
    public var resolvedContainer: ItemIdentifier? {
        switch self {
        case .trashContainer: return nil
        case .workingSet: return .rootContainer
        default: return self
        }
    }
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
        // ownCloud Classic is path-addressed: every consumer (subfolder
        // enumeration, fetchContents, delete, move, read-back) treats the item
        // identifier as a server-relative path. So the identifier is the item's
        // path — the parent's path joined with this item's name — NOT its oc:id.
        // (An oc:id identifier makes a subfolder PROPFIND target <files-root>/<oc:id>,
        // a nonexistent URL that hangs; only the root worked, its path hardcoded
        // to "/".) The name is percent-decoded and re-encoded per-segment by the
        // request builder, so a decoded path here round-trips correctly.
        let parentPath = parentIdentifier == .rootContainer ? "" : parentIdentifier.rawValue
        let path = parentPath + "/" + item.name
        self.init(
            identifier: ItemIdentifier(rawValue: path),
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

// MARK: - Space WebDAV mapping (oCIS)

public extension FileProviderItemDescription {
    /// Map a `WebDAVItem` parsed from an oCIS space's WebDAV endpoint (Task 4.5).
    ///
    /// The counterpart to ``init(webDAVItem:parentIdentifier:)``, and deliberately
    /// *not* a merge of the two: the difference is the addressing model, not a
    /// detail. Classic must be path-addressed, whereas oCIS accepts any `oc:id` as
    /// `/dav/spaces/{oc:id}` and keeps that id across rename and reparent — so
    /// here the identifier is the `oc:id`, which cannot go stale.
    ///
    /// No parent needs to be passed in either, because oCIS serves
    /// `oc:file-parent`: one Depth:0 PROPFIND by id yields identifier, parent and
    /// name together, which is what makes `item(for:)` work without href parsing.
    /// `driveID` is required only to recognise the space root, which the framework
    /// requires be reported as ``ItemIdentifier/rootContainer`` rather than under
    /// its own id.
    init(ocisWebDAVItem item: WebDAVItem, driveID: String) {
        // Fall back to the path if a server ever omits oc:id, so the item stays
        // addressable rather than collapsing onto an empty identifier.
        let identifier = item.fileID.map {
            SpaceWebDAVEndpoint.identifier(forFileID: $0, driveID: driveID)
        } ?? ItemIdentifier(rawValue: "/" + (item.serverName ?? item.name))

        // A top-level child's parent is the root's own oc:id, and the root reports
        // the bare driveID; both normalise to .rootContainer. An absent parent is
        // treated as the root too — better an item at the top level than one
        // hanging off a container the system has never heard of.
        let parent = item.parentFileID.map {
            SpaceWebDAVEndpoint.identifier(forFileID: $0, driveID: driveID)
        } ?? .rootContainer

        self.init(
            identifier: identifier,
            parentIdentifier: parent,
            // oc:name needs no percent-decoding; the href-derived name is the fallback.
            filename: item.serverName ?? item.name,
            isDirectory: item.isDirectory,
            size: item.isDirectory ? item.ocSize : item.contentLength,
            versionIdentifier: item.etag,
            contentType: item.isDirectory ? nil : item.contentType,
            contentModificationDate: item.lastModified,
            // oCIS sends the same permission letters as Classic (RDNVCKZP observed).
            capabilities: FileProviderItemDescription.capabilities(fromWebDAVPermissions: item.permissions)
        )
    }
}

