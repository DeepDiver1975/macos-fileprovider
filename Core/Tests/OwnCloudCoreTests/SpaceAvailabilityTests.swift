import XCTest
@testable import OwnCloudCore

/// Task 7.7: a space that disappears server-side. When the *root* enumeration
/// comes back 404 the whole space is gone (an admin deleted the drive, or access
/// was revoked). The extension must map that onto a **disconnect** — Finder shows
/// the reason and stops hammering every operation — and must **not** remove the
/// domain, which would discard or orphan already-materialised files without
/// consent. Every other error, and a 404 on a *non-root* item (just that item is
/// gone), stays a normal error.
///
/// The decision is pure and lives here; the `NSFileProviderManager.disconnect`
/// call is the thin Mac adapter.
final class SpaceAvailabilityTests: XCTestCase {

    func testRootNotFoundDisconnects() {
        let decision = SpaceAvailability.decide(forRootEnumeration: .noSuchItem)
        XCTAssertEqual(decision, .disconnect(reason: SpaceAvailability.spaceUnavailableReason))
    }

    func testNonRootErrorsAreSurfacedNormally() {
        // A root enumeration failing for any reason other than 404 is a normal
        // error — transient server trouble, auth, quota — not a vanished space.
        for error in [RemoteError.serverError, .authenticationRequired,
                      .insufficientPermissions, .insufficientQuota, .versionConflict] {
            XCTAssertEqual(SpaceAvailability.decide(forRootEnumeration: error), .surfaceError,
                           "\(error) must not be treated as a vanished space")
        }
    }

    func testNonRootContainerNotFoundIsANormalError() {
        // A 404 while enumerating a *sub*folder means just that folder is gone, not
        // the whole space — surface it, don't disconnect.
        let decision = SpaceAvailability.decide(
            forEnumeration: .noSuchItem, isRootContainer: false)
        XCTAssertEqual(decision, .surfaceError)
    }

    func testRootContainerNotFoundViaContainerAwareEntryPointDisconnects() {
        let decision = SpaceAvailability.decide(
            forEnumeration: .noSuchItem, isRootContainer: true)
        XCTAssertEqual(decision, .disconnect(reason: SpaceAvailability.spaceUnavailableReason))
    }

    func testReasonIsHumanReadable() {
        // Finder surfaces this string verbatim, so it must read as user-facing.
        XCTAssertFalse(SpaceAvailability.spaceUnavailableReason.isEmpty)
        XCTAssertFalse(SpaceAvailability.spaceUnavailableReason.contains("404"))
    }
}
