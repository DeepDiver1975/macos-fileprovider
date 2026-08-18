import XCTest
@testable import OwnCloudCore

/// Task 7.5 / 7.6: the cross-process `flock` primitive. Both the single-instance
/// guard (7.5) and the credential-refresh arbitration (7.6) take an exclusive
/// advisory lock on a file in the app group container. `flock` is associated with
/// the open file description, so two independent opens of the same path — the
/// shape of two processes — contend, which is what these tests exercise within one
/// process using separate `FileLock` instances.
final class FileLockTests: XCTestCase {

    private var path: String!

    override func setUpWithError() throws {
        // A unique path per test under the sandbox-writable temp dir.
        let dir = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        path = (dir as NSString).appendingPathComponent("owncloud-filelock-\(name).lock")
        try? FileManager.default.removeItem(atPath: path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: path)
    }

    func testAcquiresWhenFree() throws {
        let lock = FileLock(path: path)
        XCTAssertTrue(try lock.tryLockExclusive())
        lock.unlock()
    }

    func testSecondHolderFailsWhileFirstHolds() throws {
        let first = FileLock(path: path)
        XCTAssertTrue(try first.tryLockExclusive())
        defer { first.unlock() }

        // A second, independent open of the same path cannot take the lock.
        let second = FileLock(path: path)
        XCTAssertFalse(try second.tryLockExclusive())
    }

    func testLockIsReacquirableAfterUnlock() throws {
        let first = FileLock(path: path)
        XCTAssertTrue(try first.tryLockExclusive())
        first.unlock()

        let second = FileLock(path: path)
        XCTAssertTrue(try second.tryLockExclusive())
        second.unlock()
    }

    func testWithExclusiveLockRunsBodyThenReleases() throws {
        let lock = FileLock(path: path)
        var ran = false
        try lock.withExclusiveLock { ran = true }
        XCTAssertTrue(ran)

        // Released afterwards, so a fresh holder succeeds.
        let after = FileLock(path: path)
        XCTAssertTrue(try after.tryLockExclusive())
        after.unlock()
    }
}
