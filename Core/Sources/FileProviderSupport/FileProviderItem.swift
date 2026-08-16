#if canImport(FileProvider)
import FileProvider
import UniformTypeIdentifiers
import OwnCloudCore

/// `NSFileProviderItem` conformance over a backend-agnostic
/// ``FileProviderItemDescription`` (progress.md Task 3.1). All the mapping
/// *decisions* (identifier, size, capabilities, version source) are made in the
/// Linux-buildable core and tested there; this is the thin framework translation.
public final class FileProviderItem: NSObject, NSFileProviderItem {

    private let itemDescription: FileProviderItemDescription

    public init(itemDescription: FileProviderItemDescription) {
        self.itemDescription = itemDescription
    }

    public var itemIdentifier: NSFileProviderItemIdentifier {
        Self.identifier(itemDescription.identifier)
    }

    public var parentItemIdentifier: NSFileProviderItemIdentifier {
        Self.identifier(itemDescription.parentIdentifier)
    }

    public var filename: String { itemDescription.filename }

    public var contentType: UTType {
        itemDescription.isDirectory ? .folder : (mappedContentType ?? .data)
    }

    public var documentSize: NSNumber? {
        itemDescription.size.map { NSNumber(value: $0) }
    }

    public var contentModificationDate: Date? {
        itemDescription.contentModificationDate
    }

    /// The server etag versions both the content and the metadata: any change on
    /// the server produces a new etag, so the system re-fetches when it differs.
    public var itemVersion: NSFileProviderItemVersion {
        let token = itemDescription.versionIdentifier.map { Data($0.utf8) } ?? Data()
        return NSFileProviderItemVersion(contentVersion: token, metadataVersion: token)
    }

    public var capabilities: NSFileProviderItemCapabilities {
        var result: NSFileProviderItemCapabilities = []
        let caps = itemDescription.capabilities
        if caps.contains(.allowsReading)  { result.insert(.allowsReading) }
        if caps.contains(.allowsWriting)  { result.insert(.allowsWriting) }
        if caps.contains(.allowsRenaming) { result.insert([.allowsRenaming, .allowsReparenting]) }
        if caps.contains(.allowsDeleting) { result.insert(.allowsDeleting) }
        return result
    }

    // MARK: Helpers

    /// Map the core identifier to the framework type, translating the reserved
    /// root value onto `.rootContainer`.
    static func identifier(_ id: ItemIdentifier) -> NSFileProviderItemIdentifier {
        id == .rootContainer ? .rootContainer : NSFileProviderItemIdentifier(id.rawValue)
    }

    private var mappedContentType: UTType? {
        guard let mime = itemDescription.contentType else { return nil }
        return UTType(mimeType: mime)
    }
}
#endif
