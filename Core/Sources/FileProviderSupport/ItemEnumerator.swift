#if canImport(FileProvider)
import FileProvider
import OwnCloudCore

/// `NSFileProviderEnumerator` conformance over the backend-agnostic core
/// (progress.md Tasks 3.2/3.3). It walks the injected ``Paginator`` for a full
/// enumeration and consults the injected change provider for incremental
/// enumeration, translating both onto the framework's observer callbacks. The
/// pagination and diffing decisions live in the Linux-buildable core and are
/// tested there; this is the thin framework translation.
public final class ItemEnumerator: NSObject, NSFileProviderEnumerator {

    /// Produces the change set (and the resulting anchor) since a prior anchor.
    public typealias ChangeProvider = (_ since: SyncAnchor?) throws -> (ChangeSet, SyncAnchor)

    private let paginator: Paginator
    private let changeProvider: ChangeProvider?

    /// The most recent anchor observed from a completed enumeration, surfaced via
    /// ``currentSyncAnchor(completionHandler:)``. `nil` until the first pass.
    private var latestAnchor: SyncAnchor?

    public init(paginator: Paginator, changeProvider: ChangeProvider? = nil) {
        self.paginator = paginator
        self.changeProvider = changeProvider
    }

    public func invalidate() {
        // No long-lived resources held per enumerator.
    }

    public func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        do {
            let result = try paginator.enumerateAll()
            if let anchor = result.anchor { latestAnchor = anchor }
            observer.didEnumerate(result.items.map(FileProviderItem.init(itemDescription:)))
            observer.finishEnumerating(upTo: nil)
        } catch {
            observer.finishEnumeratingWithError(error)
        }
    }

    public func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        guard let changeProvider else {
            observer.finishEnumeratingWithError(
                NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
            )
            return
        }
        do {
            let since = SyncAnchor(data: anchor.rawValue)
            let (changeSet, newAnchor) = try changeProvider(since)
            latestAnchor = newAnchor
            observer.didUpdate(changeSet.updatedItems.map(FileProviderItem.init(itemDescription:)))
            observer.didDeleteItems(withIdentifiers: changeSet.deletedIdentifiers.map(FileProviderItem.identifier))
            observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(newAnchor.data), moreComing: false)
        } catch {
            observer.finishEnumeratingWithError(error)
        }
    }

    public func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(latestAnchor.map { NSFileProviderSyncAnchor($0.data) })
    }
}
#endif
