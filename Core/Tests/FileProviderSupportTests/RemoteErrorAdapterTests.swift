#if canImport(FileProvider)
import XCTest
import FileProvider
@testable import FileProviderSupport
import OwnCloudCore

/// The Mac-only translation of a backend-agnostic ``RemoteError`` (whose HTTP
/// classification is decided and tested in the core) into the `NSError` the
/// replicated extension's completion handlers hand back to the system. Wrong
/// codes here mean the system retries when it shouldn't, or fails to trigger
/// re-authentication — so each mapping is pinned.
final class RemoteErrorAdapterTests: XCTestCase {

    private func nsError(_ remote: RemoteError) -> NSError {
        remote.asFileProviderError as NSError
    }

    func testAuthenticationRequiredMapsToNotAuthenticated() {
        let error = nsError(.authenticationRequired)
        XCTAssertEqual(error.domain, NSFileProviderError.errorDomain)
        XCTAssertEqual(error.code, NSFileProviderError.Code.notAuthenticated.rawValue)
    }

    func testNoSuchItemMapsToNoSuchItem() {
        let error = nsError(.noSuchItem)
        XCTAssertEqual(error.domain, NSFileProviderError.errorDomain)
        XCTAssertEqual(error.code, NSFileProviderError.Code.noSuchItem.rawValue)
    }

    func testInsufficientQuotaMapsToInsufficientQuota() {
        let error = nsError(.insufficientQuota)
        XCTAssertEqual(error.domain, NSFileProviderError.errorDomain)
        XCTAssertEqual(error.code, NSFileProviderError.Code.insufficientQuota.rawValue)
    }

    func testServerErrorMapsToServerUnreachable() {
        let error = nsError(.serverError)
        XCTAssertEqual(error.domain, NSFileProviderError.errorDomain)
        XCTAssertEqual(error.code, NSFileProviderError.Code.serverUnreachable.rawValue)
    }

    func testInsufficientPermissionsMapsToCocoaWriteNoPermission() {
        // FileProvider has no dedicated permission code; a Cocoa write-no-permission
        // error is the closest the system understands (and won't blindly retry).
        let error = nsError(.insufficientPermissions)
        XCTAssertEqual(error.domain, CocoaError.errorDomain)
        XCTAssertEqual(error.code, CocoaError.Code.fileWriteNoPermission.rawValue)
    }

    func testVersionConflictMapsToCocoaFileExists() {
        // A failed If-Match / create collision: the server copy diverged from our
        // base version. Surface it as a Cocoa file-exists error the system treats
        // as a non-retryable conflict.
        let error = nsError(.versionConflict)
        XCTAssertEqual(error.domain, CocoaError.errorDomain)
        XCTAssertEqual(error.code, CocoaError.Code.fileWriteFileExists.rawValue)
    }
}
#endif
