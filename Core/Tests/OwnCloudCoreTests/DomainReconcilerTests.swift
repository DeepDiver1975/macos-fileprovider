import XCTest
@testable import OwnCloudCore

/// Task 7.4: the reconciler. A pure function that diffs three inputs into the
/// three actions the Mac-only `DomainService` (Task 7.5) then performs:
///
///   - `registry`  — which accounts are *known* (the zero-space guard).
///   - `existing`  — the sync roots the system currently has domains for
///                   (`getDomainsWithCompletionHandler`; the source of truth).
///   - `intent`    — the sync roots the user's current selection asks for.
///
/// → `add`     : in `intent`, not yet in `existing`.
/// → `remove`  : in `existing`, whose account is *known*, but no longer in `intent`
///               (a deliberate deselect).
/// → `orphans` : in `existing`, whose account is *absent* from the registry
///               (a leftover install, or an account removed while the app was closed).
final class DomainReconcilerTests: XCTestCase {

    private let einstein = AccountDescriptor(
        backend: .ocis, serverURL: URL(string: "https://ocis.test")!, username: "einstein")
    private let admin = AccountDescriptor(
        backend: .classic, serverURL: URL(string: "http://localhost:8080")!, username: "admin")

    private func record(_ account: AccountDescriptor) -> AccountRecord {
        AccountRecord(accountIdentifier: account.accountIdentifier, backend: account.backend,
                      serverURL: account.serverURL, username: account.username)
    }
    private func root(_ account: AccountDescriptor, _ driveID: String?) -> SyncRoot {
        SyncRoot(account: account, driveID: driveID)!
    }

    func testAddsIntentNotYetPresent() {
        let personal = root(einstein, "personal")
        let plan = DomainReconciler.plan(
            registry: [record(einstein)], existing: [], intent: [personal])
        XCTAssertEqual(plan.add, [personal])
        XCTAssertEqual(plan.remove, [])
        XCTAssertEqual(plan.orphans, [])
    }

    func testRemovesDeselectedSpaceOfKnownAccount() {
        let personal = root(einstein, "personal")
        let project = root(einstein, "project")
        // Both exist; the user's selection now only wants personal → project is removed.
        let plan = DomainReconciler.plan(
            registry: [record(einstein)], existing: [personal, project], intent: [personal])
        XCTAssertEqual(plan.add, [])
        XCTAssertEqual(plan.remove, [project])
        XCTAssertEqual(plan.orphans, [])
    }

    func testNoOpWhenIntentMatchesExisting() {
        let personal = root(einstein, "personal")
        let plan = DomainReconciler.plan(
            registry: [record(einstein)], existing: [personal], intent: [personal])
        XCTAssertEqual(plan.add, [])
        XCTAssertEqual(plan.remove, [])
        XCTAssertEqual(plan.orphans, [])
    }

    func testOrphansDomainWhoseAccountIsUnknown() {
        // A domain exists for an account not in the registry — a leftover install.
        let stray = root(admin, nil)
        let plan = DomainReconciler.plan(
            registry: [record(einstein)], existing: [stray], intent: [])
        XCTAssertEqual(plan.add, [])
        XCTAssertEqual(plan.remove, [])
        XCTAssertEqual(plan.orphans, [stray])
    }

    func testZeroSpaceAccountIsANoOp() {
        // A known account with no domains and no selection: it legitimately has
        // zero spaces. It must NOT be orphaned, added, or removed.
        let plan = DomainReconciler.plan(
            registry: [record(einstein)], existing: [], intent: [])
        XCTAssertEqual(plan.add, [])
        XCTAssertEqual(plan.remove, [])
        XCTAssertEqual(plan.orphans, [])
    }

    func testAccountRemovedWhileClosedOrphansAllItsDomains() {
        // The app was closed; the account was removed from the registry but its two
        // domains still exist in the system. Both are orphans — not "removes",
        // because "remove" is a deselect of a *known* account.
        let personal = root(einstein, "personal")
        let project = root(einstein, "project")
        let plan = DomainReconciler.plan(
            registry: [], existing: [personal, project], intent: [])
        XCTAssertEqual(plan.add, [])
        XCTAssertEqual(plan.remove, [])
        XCTAssertEqual(Set(plan.orphans), Set([personal, project]))
    }

    func testAddRemoveAndOrphanTogether() {
        // A mixed cycle: einstein is known, admin is not.
        let personal = root(einstein, "personal")   // stays
        let project = root(einstein, "project")      // deselected → remove
        let newSpace = root(einstein, "new")         // newly selected → add
        let stray = root(admin, nil)                 // unknown account → orphan
        let plan = DomainReconciler.plan(
            registry: [record(einstein)],
            existing: [personal, project, stray],
            intent: [personal, newSpace])
        XCTAssertEqual(plan.add, [newSpace])
        XCTAssertEqual(plan.remove, [project])
        XCTAssertEqual(plan.orphans, [stray])
    }
}
