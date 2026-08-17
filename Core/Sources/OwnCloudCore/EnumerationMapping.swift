import Foundation

/// Maps a parsed backend enumeration response onto an ``EnumerationPage`` — the
/// pure half of a `Paginator.FetchPage` (progress.md Phase 3). No networking:
/// the WebDAV/Graph client fetches and parses; these initializers turn the
/// parsed models into the engine's page type.
public extension EnumerationPage {

    /// Build a page from a WebDAV `PROPFIND Depth:1` listing. Depth:1 returns the
    /// container itself as the first entry alongside its children; that self
    /// entry (the response whose href matches the requested container) is dropped
    /// so only children are enumerated. Classic returns every child at once, so
    /// there is no next cursor and the anchor is synthesized elsewhere.
    init(webDAVItems: [WebDAVItem], containerHref: String, parentIdentifier: ItemIdentifier) {
        let containerPath = Self.normalizedPath(containerHref)
        let children = webDAVItems.filter { Self.normalizedPath($0.href) != containerPath }
        self.init(
            items: children.map { FileProviderItemDescription(webDAVItem: $0, parentIdentifier: parentIdentifier) },
            nextCursor: nil,
            anchor: nil
        )
    }

    /// Build a page from an oCIS Graph item collection. `nextToken` (from
    /// `@odata.nextLink`) becomes the cursor for the next page within this
    /// enumeration; `deltaToken` (from `@odata.deltaLink`, present only on the
    /// final page) becomes the sync anchor handed back once enumeration completes.
    init(graphCollection: GraphItemCollection) {
        self.init(
            items: graphCollection.items.map(FileProviderItemDescription.init(graphItem:)),
            nextCursor: graphCollection.nextToken.map(PageCursor.init(rawValue:)),
            anchor: graphCollection.deltaToken.map(SyncAnchor.init(token:))
        )
    }

    /// Normalise an href for self-entry comparison: strip a trailing slash so
    /// `/a/b/` and `/a/b` compare equal. Percent-encoding is left intact — both
    /// the container path and the server hrefs are encoded the same way.
    private static func normalizedPath(_ href: String) -> String {
        href.hasSuffix("/") ? String(href.dropLast()) : href
    }
}
