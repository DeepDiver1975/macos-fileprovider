import Foundation

/// Detects locally-changed items and queues them for upload without duplication
/// (progress.md Task 4.3). Pure bookkeeping — the actual upload is driven by the
/// extension's `modifyItem`/`createItem` handlers using `RemoteRequest`s.
///
/// A change is "genuine" when the local content version (etag/hash) differs from
/// the version last synced to the server. An item already pending is not
/// re-enqueued (its upload will pick up the latest bytes when it runs); once
/// dequeued, a further local change enqueues it again.
public struct UploadQueue {

    private var order: [ItemIdentifier] = []
    private var pending: Set<ItemIdentifier> = []

    public init() {}

    /// Identifiers currently awaiting upload, in FIFO order.
    public var pendingIdentifiers: [ItemIdentifier] { order }

    /// Enqueue `identifier` if its local version differs from the last synced
    /// version and it is not already pending. Returns whether it was enqueued.
    @discardableResult
    public mutating func enqueueIfChanged(
        identifier: ItemIdentifier,
        localVersion: String,
        lastSyncedVersion: String?
    ) -> Bool {
        guard localVersion != lastSyncedVersion else { return false }
        guard !pending.contains(identifier) else { return false }
        pending.insert(identifier)
        order.append(identifier)
        return true
    }

    /// Remove and return the next pending identifier (FIFO), or `nil` if empty.
    @discardableResult
    public mutating func dequeue() -> ItemIdentifier? {
        guard !order.isEmpty else { return nil }
        let next = order.removeFirst()
        pending.remove(next)
        return next
    }
}
