import XCTest
@testable import OwnCloudCore

/// Smoke test proving the Task 1.4 harness (`swift test` over the core package)
/// is wired up and green. Phase 2 tests replace/extend this.
final class OwnCloudCoreTests: XCTestCase {
    func testVersionIsSet() {
        XCTAssertFalse(OwnCloudCore.version.isEmpty)
    }
}
