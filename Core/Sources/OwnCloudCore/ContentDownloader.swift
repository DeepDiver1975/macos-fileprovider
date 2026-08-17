import Foundation

/// Downloads an item's bytes to a temporary file and returns that URL — the
/// reusable core of the replicated-extension `fetchContents` contract
/// (progress.md Tasks 4.1/4.2): the extension downloads to a location **it**
/// chooses and hands the URL back, after which the system takes ownership and
/// moves the file into its own replicated store.
///
/// The backend fetch request (WebDAV GET at the item path, or Graph GET on
/// `/items/{id}/content`) is shaped by the builders and passed in; the transport
/// is the injected ``RemoteClient``. Deliberately no long-lived cache — the system
/// already stores hydrated content, so a self-managed cache would double-store
/// every file.
public struct ContentDownloader {

    private let client: RemoteClient
    private let destinationDirectory: URL

    /// - Parameters:
    ///   - client: the transport seam (injected performer in tests, `URLSession`
    ///     in production).
    ///   - destinationDirectory: where temp files are written. In the extension
    ///     this is a provider temp directory; defaults to `NSTemporaryDirectory()`.
    public init(client: RemoteClient, destinationDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory())) {
        self.client = client
        self.destinationDirectory = destinationDirectory
    }

    /// Fetch `request`'s body and write it to a fresh, unique temp file, returning
    /// that URL. Throws the classified ``RemoteError`` on an HTTP failure (and
    /// writes nothing), or a transport error unchanged.
    public func download(_ request: RemoteRequest, authorization: String?) async throws -> URL {
        // Fetch first: if send throws (classified HTTP failure or transport
        // error), no temp file is created, so a failed hydration leaves nothing
        // behind for the system to adopt.
        let data = try await client.send(request, authorization: authorization)
        let destination = destinationDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: destination, options: .atomic)
        return destination
    }
}
