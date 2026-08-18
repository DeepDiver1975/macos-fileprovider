import XCTest
@testable import OwnCloudCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Classic (WebDAV) fixture-state action bodies (Task 6.3 harness half): the
/// server-side operations an acceptance scenario's Given/When steps drive — create a
/// file, create a folder with N files, delete a file. These are what the acceptance
/// step library binds "the server has a file {string}", "a file {string} is created
/// on the server", "the server has a folder {string} containing {int} files", and
/// "the file {string} is deleted on the server" onto.
///
/// `ClassicBackendAdmin` is pure orchestration over an injected `RemoteClient`, so
/// the request shaping / sequencing is proven headlessly by capturing the
/// `URLRequest`s the transport receives — the same client type wired to a live
/// `URLSession` runs it against the Docker fixture (round-trip proven live
/// 2026-08-18). Only the transport closure is injected.
final class ClassicBackendAdminTests: XCTestCase {

    private let filesBase = URL(string: "https://cloud.test/remote.php/dav/files/admin")!

    /// Collects the URLRequests the transport is asked to perform, in order, and
    /// replies with a fixed status.
    private final class Transport: @unchecked Sendable {
        private(set) var seen: [URLRequest] = []
        let status: Int
        init(status: Int) { self.status = status }
        func client(base: URL) -> RemoteClient {
            RemoteClient { [self] req in
                seen.append(req)
                let http = HTTPURLResponse(url: req.url ?? base, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (Data(), http)
            }
        }
    }

    /// Creating a file PUTs its bytes at the file's path under the files root.
    func testCreateFilePutsBytesAtPath() async throws {
        let transport = Transport(status: 201)
        let admin = ClassicBackendAdmin(filesBaseURL: filesBase, client: transport.client(base: filesBase))

        try await admin.createFile(path: "report.pdf", contents: Data("hello".utf8))

        XCTAssertEqual(transport.seen.count, 1)
        XCTAssertEqual(transport.seen[0].httpMethod, "PUT")
        XCTAssertEqual(transport.seen[0].url, filesBase.appendingPathComponent("report.pdf"))
        XCTAssertEqual(transport.seen[0].httpBody, Data("hello".utf8))
    }

    /// A folder-with-N-files first MKCOLs the folder, then PUTs N distinctly-named
    /// files inside it.
    func testCreateFolderMakesCollectionThenUploadsNFiles() async throws {
        let transport = Transport(status: 201)
        let admin = ClassicBackendAdmin(filesBaseURL: filesBase, client: transport.client(base: filesBase))

        try await admin.createFolder(path: "Big", fileCount: 3)

        XCTAssertEqual(transport.seen.count, 4, "one MKCOL + three PUTs")
        XCTAssertEqual(transport.seen[0].httpMethod, "MKCOL")
        XCTAssertEqual(transport.seen[0].url, filesBase.appendingPathComponent("Big"))
        let folderPrefix = filesBase.appendingPathComponent("Big").absoluteString + "/"
        for put in transport.seen[1...] {
            XCTAssertEqual(put.httpMethod, "PUT")
            XCTAssertTrue((put.url?.absoluteString ?? "").hasPrefix(folderPrefix), put.url?.absoluteString ?? "")
        }
        let names = Set(transport.seen[1...].map { $0.url?.lastPathComponent })
        XCTAssertEqual(names.count, 3, "each of the N files has a distinct name")
    }

    /// Deleting a file issues a DELETE at its path.
    func testDeleteFileIssuesDelete() async throws {
        let transport = Transport(status: 204)
        let admin = ClassicBackendAdmin(filesBaseURL: filesBase, client: transport.client(base: filesBase))

        try await admin.deleteFile(path: "doomed.txt")

        XCTAssertEqual(transport.seen.count, 1)
        XCTAssertEqual(transport.seen[0].httpMethod, "DELETE")
        XCTAssertEqual(transport.seen[0].url, filesBase.appendingPathComponent("doomed.txt"))
    }

    /// A non-2xx response propagates as a `RemoteError` — the harness must see a
    /// failed provisioning step, never a silent no-op.
    func testServerFailurePropagates() async {
        let transport = Transport(status: 500)
        let admin = ClassicBackendAdmin(filesBaseURL: filesBase, client: transport.client(base: filesBase))

        do {
            try await admin.createFile(path: "x.txt", contents: Data())
            XCTFail("expected the 500 to throw")
        } catch {
            XCTAssertTrue(error is RemoteError, "\(error)")
        }
    }
}
