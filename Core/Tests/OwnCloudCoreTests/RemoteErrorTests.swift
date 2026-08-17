import XCTest
@testable import OwnCloudCore

/// Tasks 4.1–4.4: when a backend operation fails, the replicated extension must
/// hand the system a *semantic* error so it retries, re-authenticates, or
/// surfaces a conflict correctly. The classification of an HTTP status into that
/// semantic kind is backend-agnostic and lives in the core; the translation to
/// `NSError`/`NSFileProviderError` is the Mac-only adapter (tested there).
final class RemoteErrorTests: XCTestCase {

    func testUnauthorizedMapsToAuthenticationRequired() {
        XCTAssertEqual(RemoteError(statusCode: 401), .authenticationRequired)
    }

    func testForbiddenMapsToInsufficientPermissions() {
        XCTAssertEqual(RemoteError(statusCode: 403), .insufficientPermissions)
    }

    func testNotFoundMapsToNoSuchItem() {
        XCTAssertEqual(RemoteError(statusCode: 404), .noSuchItem)
    }

    func testPreconditionFailedMapsToVersionConflict() {
        // If-Match failed: the item changed on the server since our base version.
        XCTAssertEqual(RemoteError(statusCode: 412), .versionConflict)
    }

    func testConflictMapsToVersionConflict() {
        XCTAssertEqual(RemoteError(statusCode: 409), .versionConflict)
    }

    func testInsufficientStorageMapsToInsufficientQuota() {
        XCTAssertEqual(RemoteError(statusCode: 507), .insufficientQuota)
    }

    func testServerErrorMapsToServerError() {
        XCTAssertEqual(RemoteError(statusCode: 500), .serverError)
        XCTAssertEqual(RemoteError(statusCode: 503), .serverError)
    }

    func testUnknownClientErrorMapsToServerError() {
        // Any other non-2xx we can't classify is treated as a transient/server
        // failure rather than silently swallowed.
        XCTAssertEqual(RemoteError(statusCode: 418), .serverError)
    }

    func testSuccessStatusesDoNotMapToAnError() {
        XCTAssertNil(RemoteError(statusCode: 200))
        XCTAssertNil(RemoteError(statusCode: 201))
        XCTAssertNil(RemoteError(statusCode: 204))
        XCTAssertNil(RemoteError(statusCode: 207))
    }
}
