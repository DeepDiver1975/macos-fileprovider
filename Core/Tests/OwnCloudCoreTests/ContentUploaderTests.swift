import XCTest
@testable import OwnCloudCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The upload half of the push handlers (progress.md Task 4.4): `createItem` and
/// `modifyItem` stream a local file's bytes to the backend (WebDAV `PUT`, or Graph
/// `PUT /content`). `ContentUploader` is that reusable core — read the file, send
/// it as the request body over a ``RemoteClient``, and map the outcome, including
/// the optimistic-concurrency conflict (`If-Match` → 412/409) that is the Phase 4
/// conflict question. The `NSFileProviderReplicatedExtension` handler wiring stays
/// in the Mac-only extension.
final class ContentUploaderTests: XCTestCase {

    private var scratch: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ContentUploaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        fileURL = scratch.appendingPathComponent("upload.bin")
        try Data("local file bytes".utf8).write(to: fileURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func client(
        status: Int,
        body: Data = Data(),
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

    private var putRequest: RemoteRequest {
        RemoteRequest(
            method: .put,
            url: URL(string: "https://cloud.test/remote.php/dav/files/admin/upload.bin")!,
            hasBody: true
        )
    }

    func testStreamsTheFileBytesAsTheRequestBody() async throws {
        var seen: URLRequest?
        let uploader = ContentUploader(client: client(status: 201, capture: { seen = $0 }))

        try await uploader.upload(putRequest, fromFile: fileURL, authorization: "Basic abc")

        XCTAssertEqual(seen?.httpMethod, "PUT")
        XCTAssertEqual(seen?.httpBody, Data("local file bytes".utf8))
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Basic abc")
    }

    func testSucceedsOnCreated() async throws {
        let uploader = ContentUploader(client: client(status: 201))
        // No throw == success.
        try await uploader.upload(putRequest, fromFile: fileURL, authorization: nil)
    }

    func testSucceedsOnNoContent() async throws {
        // WebDAV modify of an existing file returns 204.
        let uploader = ContentUploader(client: client(status: 204))
        try await uploader.upload(putRequest, fromFile: fileURL, authorization: nil)
    }

    func testMapsPreconditionFailedToVersionConflict() async {
        // If-Match mismatch: the remote changed since baseVersion — a conflict.
        let uploader = ContentUploader(client: client(status: 412))
        do {
            try await uploader.upload(putRequest, fromFile: fileURL, authorization: nil)
            XCTFail("expected a thrown error")
        } catch let error as RemoteError {
            XCTAssertEqual(error, .versionConflict)
        } catch {
            XCTFail("expected RemoteError, got \(error)")
        }
    }

    func testMapsInsufficientStorageToQuota() async {
        let uploader = ContentUploader(client: client(status: 507))
        do {
            try await uploader.upload(putRequest, fromFile: fileURL, authorization: nil)
            XCTFail("expected a thrown error")
        } catch let error as RemoteError {
            XCTAssertEqual(error, .insufficientQuota)
        } catch {
            XCTFail("expected RemoteError, got \(error)")
        }
    }

    func testThrowsWhenTheLocalFileIsMissing() async {
        let uploader = ContentUploader(client: client(status: 201))
        let missing = scratch.appendingPathComponent("does-not-exist.bin")
        do {
            try await uploader.upload(putRequest, fromFile: missing, authorization: nil)
            XCTFail("expected a thrown error")
        } catch is RemoteError {
            XCTFail("a missing local file is not a remote error")
        } catch {
            // expected — reading the file fails before any request is sent.
        }
    }

    // MARK: Upload returning the response body (oCIS reconciliation)

    func testUploadReturningBodyStreamsFileAndReturnsResponseBytes() async throws {
        // oCIS returns the created/modified driveItem JSON in the response body,
        // which the extension decodes to reconcile the server-assigned id + eTag.
        var seen: URLRequest?
        let responseJSON = Data(#"{ "id": "srv-1", "name": "upload.bin" }"#.utf8)
        let uploader = ContentUploader(client: client(status: 201, body: responseJSON, capture: { seen = $0 }))

        let body = try await uploader.uploadReturningBody(putRequest, fromFile: fileURL, authorization: "Bearer t")

        XCTAssertEqual(seen?.httpBody, Data("local file bytes".utf8))
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Bearer t")
        XCTAssertEqual(body, responseJSON)
    }

    func testUploadReturningBodyMapsConflict() async {
        let uploader = ContentUploader(client: client(status: 412))
        do {
            _ = try await uploader.uploadReturningBody(putRequest, fromFile: fileURL, authorization: nil)
            XCTFail("expected a thrown error")
        } catch let error as RemoteError {
            XCTAssertEqual(error, .versionConflict)
        } catch {
            XCTFail("expected RemoteError, got \(error)")
        }
    }
}
