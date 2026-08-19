import Foundation

/// A backend page fetcher for enumeration — the live-fetch seam that connects the
/// pure request builders and response parsers to the pagination engine
/// (progress.md Phase 3). It issues the enumerate request over a ``RemoteClient``,
/// parses/decodes the response, and maps it onto an ``EnumerationPage``.
///
/// It is the async counterpart of ``Paginator/FetchPage``: `Paginator` is the
/// synchronous accumulator used by the Mac enumerator adapter, while a source
/// performs real (`async`) I/O. ``enumerateAll(from:)`` walks a source to
/// completion the same way `Paginator.enumerateAll()` walks its closure.
public protocol RemoteEnumerationSource {
    /// Fetch the page beginning at `cursor` (`nil` = first page).
    func fetchPage(cursor: PageCursor?) async throws -> EnumerationPage
}

/// Walk a ``RemoteEnumerationSource`` page by page until there is no next cursor,
/// accumulating items in order and capturing the final sync anchor — the async
/// analogue of ``Paginator/enumerateAll()``.
public func enumerateAll(from source: RemoteEnumerationSource) async throws -> EnumerationResult {
    var items: [FileProviderItemDescription] = []
    var cursor: PageCursor? = nil
    var latestAnchor: SyncAnchor? = nil

    repeat {
        let page = try await source.fetchPage(cursor: cursor)
        items.append(contentsOf: page.items)
        if let anchor = page.anchor { latestAnchor = anchor }
        cursor = page.nextCursor
    } while cursor != nil

    return EnumerationResult(items: items, anchor: latestAnchor)
}

/// Defers building the underlying ``RemoteEnumerationSource`` until the first
/// page is fetched, then caches it. Needed because oCIS enumeration needs a
/// `driveID` that is only known after an async `me/drives` lookup, while the Mac
/// enumerator builds its source synchronously — this bridges the two by taking an
/// async factory. The factory runs at most once even under concurrent fetches.
public struct LazyRemoteEnumerationSource: RemoteEnumerationSource {

    private let cache: SourceCache

    public init(_ makeSource: @escaping @Sendable () async throws -> RemoteEnumerationSource) {
        self.cache = SourceCache(makeSource)
    }

    public func fetchPage(cursor: PageCursor?) async throws -> EnumerationPage {
        let source = try await cache.source()
        return try await source.fetchPage(cursor: cursor)
    }

    /// Serializes construction so the factory runs once; a second caller awaits the
    /// same in-flight build rather than starting its own.
    private actor SourceCache {
        private let makeSource: @Sendable () async throws -> RemoteEnumerationSource
        private var built: Task<RemoteEnumerationSource, Error>?

        init(_ makeSource: @escaping @Sendable () async throws -> RemoteEnumerationSource) {
            self.makeSource = makeSource
        }

        func source() async throws -> RemoteEnumerationSource {
            if let built { return try await built.value }
            let task = Task { try await makeSource() }
            built = task
            do {
                return try await task.value
            } catch {
                // Don't cache a failed build — a later fetch may succeed (e.g. once
                // credentials are present).
                built = nil
                throw error
            }
        }
    }
}

/// Enumerates an ownCloud Classic (WebDAV) container: a single `PROPFIND Depth:1`
/// listing the immediate children. Classic has no delta API and returns every
/// child at once, so there is exactly one page and the sync anchor is synthesized
/// from the children (matching ``SyncAnchor/init(listing:)`` so `enumerateChanges`
/// can re-list and compare).
public struct WebDAVEnumerationSource: RemoteEnumerationSource {
    private let client: RemoteClient
    private let builder: WebDAVRequestBuilder
    private let containerPath: String
    private let containerHref: String
    private let parentIdentifier: ItemIdentifier
    private let authorization: String?

    public init(
        client: RemoteClient,
        builder: WebDAVRequestBuilder,
        containerPath: String,
        containerHref: String,
        parentIdentifier: ItemIdentifier,
        authorization: String?
    ) {
        self.client = client
        self.builder = builder
        self.containerPath = containerPath
        self.containerHref = containerHref
        self.parentIdentifier = parentIdentifier
        self.authorization = authorization
    }

    public func fetchPage(cursor: PageCursor?) async throws -> EnumerationPage {
        let data = try await client.send(builder.enumerate(path: containerPath), authorization: authorization)
        let items = try WebDAVMultiStatusParser().parse(data)
        let page = EnumerationPage(
            webDAVItems: items,
            containerHref: containerHref,
            parentIdentifier: parentIdentifier
        )
        // Classic has no delta token: synthesize the anchor from the children so a
        // later enumerateChanges can detect any add/remove/version change.
        return EnumerationPage(
            items: page.items,
            nextCursor: nil,
            anchor: SyncAnchor(listing: page.items)
        )
    }
}

/// Enumerates a container in an oCIS space over that space's own WebDAV endpoint
/// (Task 4.5) — a `PROPFIND Depth:1`, exactly as Classic, differing only in how
/// the container is addressed: by `oc:id` rather than by path.
///
/// This replaces the former Graph-based source. oCIS 8.2.0 does not serve the
/// Graph endpoints that layer targeted (`/root/children` 404s, and so do the
/// content routes), whereas `/dav/spaces/{driveID}` answers every WebDAV verb.
/// `owncloud/client` is arranged the same way: Graph lists drives, and the
/// per-space `webDavUrl` is handed to the same jobs Classic uses.
///
/// Like Classic there is no delta token, so the anchor is synthesized from the
/// listing and there is exactly one page.
public struct OCISWebDAVEnumerationSource: RemoteEnumerationSource {
    private let client: RemoteClient
    private let builder: WebDAVRequestBuilder
    /// The container's address relative to the space WebDAV base: `/` for the
    /// space root, else `/{oc:id}`.
    private let containerPath: String
    /// The container's own `oc:id`, used to drop the Depth:1 self entry. `nil` for
    /// the space root, whose id is recognised structurally instead.
    private let containerFileID: String?
    private let driveID: String
    private let authorization: String?

    public init(
        client: RemoteClient,
        builder: WebDAVRequestBuilder,
        containerPath: String,
        containerFileID: String?,
        driveID: String,
        authorization: String?
    ) {
        self.client = client
        self.builder = builder
        self.containerPath = containerPath
        self.containerFileID = containerFileID
        self.driveID = driveID
        self.authorization = authorization
    }

    public func fetchPage(cursor: PageCursor?) async throws -> EnumerationPage {
        let data = try await client.send(builder.enumerate(path: containerPath), authorization: authorization)
        let items = try WebDAVMultiStatusParser().parse(data)
        let page = EnumerationPage(
            ocisWebDAVItems: items,
            containerFileID: containerFileID,
            driveID: driveID
        )
        return EnumerationPage(
            items: page.items,
            nextCursor: nil,
            anchor: SyncAnchor(listing: page.items)
        )
    }
}
