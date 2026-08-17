import Foundation

/// Streams a local file's bytes to the backend — the upload core of the push
/// handlers (progress.md Task 4.4). `createItem` and `modifyItem` shape their
/// request with the WebDAV/Graph builders (`PUT`, or Graph `PUT /content`, with an
/// `If-Match` for optimistic concurrency) and hand it here with the file the
/// system provided; this reads the file and sends it as the request body over a
/// ``RemoteClient``.
///
/// HTTP failures surface as the classified ``RemoteError`` — notably
/// `versionConflict` (412/409) when an `If-Match` precondition fails, which is the
/// signal the extension turns into the replicated-provider conflict outcome.
public struct ContentUploader {

    private let client: RemoteClient

    public init(client: RemoteClient) {
        self.client = client
    }

    /// Upload the contents of `fileURL` as `request`'s body. Returns normally on a
    /// 2xx; throws the classified ``RemoteError`` on an HTTP failure, or the
    /// underlying error if the local file cannot be read (which happens before any
    /// request is sent, so nothing is uploaded).
    public func upload(_ request: RemoteRequest, fromFile fileURL: URL, authorization: String?) async throws {
        _ = try await uploadReturningBody(request, fromFile: fileURL, authorization: authorization)
    }

    /// Like ``upload(_:fromFile:authorization:)`` but returns the response body —
    /// oCIS answers a create/modify with the resulting `driveItem` JSON, which the
    /// extension decodes (``GraphJSONDecoder/decodeItem(_:)``) to reconcile the
    /// server-assigned id and new eTag. Same failure mapping.
    @discardableResult
    public func uploadReturningBody(_ request: RemoteRequest, fromFile fileURL: URL, authorization: String?) async throws -> Data {
        let body = try Data(contentsOf: fileURL)
        return try await client.send(request, body: body, authorization: authorization)
    }
}
