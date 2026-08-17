import XCTest
@testable import OwnCloudCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The download half of file hydration (progress.md Tasks 4.1/4.2). The
/// replicated-extension `fetchContents` contract is: download the item's bytes to
/// a temporary location the extension chooses, then hand that URL back for the
/// system to take ownership of. `ContentDownloader` is that reusable core — issue
/// the backend's fetch request over a ``RemoteClient`` and write the body to a
/// fresh temp file — leaving only the framework completion-handler wiring to the
/// Mac-only extension.
///
/// Driven with an injected performer, so no live server is needed.
final class ContentDownloaderTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        // A per-test scratch directory so the chosen temp URLs are isolated.
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ContentDownloaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func client(
        status: Int = 200,
        body: Data,
        capture: ((URLRequest) -> Void)? = nil
    ) -> RemoteClient {
        RemoteClient { urlRequest in
            capture?(urlRequest)
            let response = HTTPURLResponse(
                url: urlRequest.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (body, response)
        }
    }

    func testWritesDownloadedBytesToATempFileAndReturnsTheURL() async throws {
        let payload = Data("the file contents".utf8)
        let downloader = ContentDownloader(client: client(body: payload), destinationDirectory: scratch)
        let request = RemoteRequest(method: .get, url: URL(string: "https://cloud.test/remote.php/dav/files/admin/a.txt")!)

        let url = try await downloader.download(request, authorization: "Basic abc")

        XCTAssertTrue(url.path.hasPrefix(scratch.path), "the temp file lands in the chosen directory")
        XCTAssertEqual(try Data(contentsOf: url), payload)
    }

    func testEachDownloadGetsAUniqueTempURL() async throws {
        let downloader = ContentDownloader(client: client(body: Data("x".utf8)), destinationDirectory: scratch)
        let request = RemoteRequest(method: .get, url: URL(string: "https://cloud.test/a.txt")!)

        let first = try await downloader.download(request, authorization: nil)
        let second = try await downloader.download(request, authorization: nil)

        XCTAssertNotEqual(first, second, "concurrent hydrations must not collide on one path")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testSendsTheRequestWithAuthorization() async throws {
        var seen: URLRequest?
        let downloader = ContentDownloader(client: client(body: Data(), capture: { seen = $0 }), destinationDirectory: scratch)
        let request = RemoteRequest(method: .get, url: URL(string: "https://cloud.test/a.txt")!)

        _ = try await downloader.download(request, authorization: "Bearer tok")

        XCTAssertEqual(seen?.url?.absoluteString, "https://cloud.test/a.txt")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func testEmptyFileHydratesToAnEmptyTempFile() async throws {
        let downloader = ContentDownloader(client: client(body: Data()), destinationDirectory: scratch)
        let request = RemoteRequest(method: .get, url: URL(string: "https://cloud.test/empty.txt")!)

        let url = try await downloader.download(request, authorization: nil)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: url).count, 0)
    }

    func testThrowsClassifiedErrorAndWritesNoFileOnFailure() async throws {
        let downloader = ContentDownloader(client: client(status: 404, body: Data()), destinationDirectory: scratch)
        let request = RemoteRequest(method: .get, url: URL(string: "https://cloud.test/gone.txt")!)

        do {
            _ = try await downloader.download(request, authorization: nil)
            XCTFail("expected a thrown error")
        } catch let error as RemoteError {
            XCTAssertEqual(error, .noSuchItem)
        }
        // A failed hydration leaves no stray temp files behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        XCTAssertTrue(leftovers.isEmpty, "no partial temp file on failure, got \(leftovers)")
    }
}
