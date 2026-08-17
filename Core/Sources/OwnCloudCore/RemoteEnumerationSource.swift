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

/// Enumerates an oCIS drive via Graph: the first page is `/root/children`,
/// subsequent pages follow the opaque `$token` against `/root/delta` (the same
/// endpoint that powers change tracking). `@odata.nextLink` becomes the next
/// cursor; `@odata.deltaLink` (final page only) becomes the sync anchor.
public struct GraphEnumerationSource: RemoteEnumerationSource {
    private let client: RemoteClient
    private let builder: GraphRequestBuilder
    private let driveID: String
    private let authorization: String?

    public init(
        client: RemoteClient,
        builder: GraphRequestBuilder,
        driveID: String,
        authorization: String?
    ) {
        self.client = client
        self.builder = builder
        self.driveID = driveID
        self.authorization = authorization
    }

    public func fetchPage(cursor: PageCursor?) async throws -> EnumerationPage {
        let data = try await client.send(builder.enumerate(driveID: driveID, cursor: cursor), authorization: authorization)
        let collection = try GraphJSONDecoder().decodeItemCollection(data)
        return EnumerationPage(graphCollection: collection)
    }
}
