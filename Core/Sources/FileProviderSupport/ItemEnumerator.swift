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

    /// Runs a full enumeration to completion. Both the synchronous ``Paginator``
    /// and the async ``RemoteEnumerationSource`` are adapted onto this one shape so
    /// the observer plumbing below is identical for the in-memory test path and
    /// the real network-backed path.
    private let enumerate: () async throws -> EnumerationResult
    private let changeProvider: ChangeProvider?
    /// Reacts to a vanished space (Task 7.7). Consulted when this enumerator is for
    /// the root container and enumeration fails; a root-404 disconnects the domain
    /// (never removes it). `nil` for non-root enumerators and the in-memory path.
    private let availabilityReactor: SpaceAvailabilityReacting?
    private let isRootContainer: Bool

    /// The most recent anchor observed from a completed enumeration, surfaced via
    /// ``currentSyncAnchor(completionHandler:)``. `nil` until the first pass.
    private var latestAnchor: SyncAnchor?

    /// Synchronous, in-memory enumeration over a ``Paginator`` (used by tests and
    /// any source that has the pages in hand).
    public init(paginator: Paginator, changeProvider: ChangeProvider? = nil) {
        self.enumerate = { try paginator.enumerateAll() }
        self.changeProvider = changeProvider
        self.availabilityReactor = nil
        self.isRootContainer = false
    }

    /// Network-backed enumeration: walks a ``RemoteEnumerationSource`` (WebDAV or
    /// Graph) page by page over real async I/O.
    ///
    /// `isRootContainer` and `availabilityReactor` wire Task 7.7: when the root
    /// enumeration returns 404 the space has vanished and the domain is disconnected
    /// with a user-facing reason, rather than failing every operation forever.
    public init(source: RemoteEnumerationSource,
                changeProvider: ChangeProvider? = nil,
                isRootContainer: Bool = false,
                availabilityReactor: SpaceAvailabilityReacting? = nil) {
        self.enumerate = { try await enumerateAll(from: source) }
        self.changeProvider = changeProvider
        self.isRootContainer = isRootContainer
        self.availabilityReactor = availabilityReactor
    }

    public func invalidate() {
        // No long-lived resources held per enumerator.
    }

    public func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let enumerate = self.enumerate
        Task {
            do {
                let result = try await enumerate()
                if let anchor = result.anchor { self.latestAnchor = anchor }
                observer.didEnumerate(result.items.map(FileProviderItem.init(itemDescription:)))
                observer.finishEnumerating(upTo: nil)
            } catch {
                // Task 7.7: a root-404 means the space vanished — disconnect the
                // domain (keeping downloaded files) instead of just failing.
                if isRootContainer, let reactor = availabilityReactor,
                   let remote = error as? RemoteError,
                   case let .disconnect(reason) = SpaceAvailability.decide(forRootEnumeration: remote) {
                    await reactor.disconnect(reason: reason)
                }
                observer.finishEnumeratingWithError(error)
            }
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
