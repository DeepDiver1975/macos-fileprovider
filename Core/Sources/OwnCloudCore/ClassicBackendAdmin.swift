import Foundation

/// The Classic (WebDAV) fixture-state action bodies for the acceptance harness
/// (Task 6.3): the server-side operations a scenario's Given/When steps drive to put
/// the fixture into a known state — create a file, create a folder containing N
/// files, delete a file. The acceptance step library binds the "the server has a
/// file …", "a file … is created on the server", "the server has a folder …
/// containing N files", and "the file … is deleted on the server" steps onto these.
///
/// It is pure orchestration over an injected ``RemoteClient`` (reusing
/// ``WebDAVRequestBuilder`` for the request shaping), so the sequencing is tested
/// headlessly with a stub transport; wired to a live `URLSession`-backed client it
/// provisions the real Docker fixture. A non-2xx response propagates as
/// ``RemoteError`` so a failed provisioning step surfaces rather than silently
/// no-op'ing.
public struct ClassicBackendAdmin: Sendable {

    private let builder: WebDAVRequestBuilder
    private let client: RemoteClient
    private let authorization: String?

    public init(filesBaseURL: URL, client: RemoteClient, authorization: String? = nil) {
        self.builder = WebDAVRequestBuilder(filesBaseURL: filesBaseURL)
        self.client = client
        self.authorization = authorization
    }

    /// PUT `contents` at `path` (relative to the files root).
    public func createFile(path: String, contents: Data) async throws {
        try await client.send(builder.createFile(path: path), body: contents, authorization: authorization)
    }

    /// MKCOL the folder at `path`, then PUT `fileCount` distinctly-named files into
    /// it — the "folder containing N files" fixture the large-enumeration scenario
    /// needs. Files are named `file-1`…`file-N` so all N land as distinct items.
    public func createFolder(path: String, fileCount: Int) async throws {
        try await client.send(builder.createDirectory(path: path), authorization: authorization)
        guard fileCount > 0 else { return }
        for index in 1...fileCount {
            let filePath = "\(path)/file-\(index).txt"
            let body = Data("file \(index)\n".utf8)
            try await client.send(builder.createFile(path: filePath), body: body, authorization: authorization)
        }
    }

    /// DELETE the item at `path`.
    public func deleteFile(path: String) async throws {
        try await client.send(builder.delete(path: path), authorization: authorization)
    }
}
