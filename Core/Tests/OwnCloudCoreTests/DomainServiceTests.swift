import XCTest
@testable import OwnCloudCore

/// Task 7.5: the domain service's orchestration and — the part that makes crashes
/// recoverable — its **ordering**. The service is pure over three seams (the
/// platform domain manager, the account registry, and per-account credential
/// deletion, plus a single-instance lock); the Mac-only adapter wiring
/// `NSFileProviderManager`/Keychain into those seams is thin and lives in
/// `FileProviderSupport`.
///
/// Ordering the registry brackets the domain lifetime:
///   - on add: write the account record **before** adding the domain (a zero-space
///     account is legal, so the record can exist with no domains);
///   - on sign-out: remove domains → delete credentials → delete the record **last**
///     (an orphan domain is detectable; a missing credential just reads as "signed out").
final class DomainServiceTests: XCTestCase {

    private let einstein = AccountDescriptor(
        backend: .ocis, serverURL: URL(string: "https://ocis.test")!, username: "einstein")
    private let admin = AccountDescriptor(
        backend: .classic, serverURL: URL(string: "http://localhost:8080")!, username: "admin")

    private func root(_ account: AccountDescriptor, _ driveID: String?) -> SyncRoot {
        SyncRoot(account: account, driveID: driveID)!
    }

    // MARK: - Add: record before domain

    func testAddSpaceWritesRecordBeforeAddingDomain() async throws {
        let f = Fixture()
        let personal = root(einstein, "personal")

        try await f.service.addSpace(personal, displayName: "Personal")

        XCTAssertEqual(f.recorder.events, [
            "record+ \(einstein.accountIdentifier)",
            "domain+ \(personal.domainIdentifier)",
        ])
    }

    // MARK: - Sign out: domains → credentials → record last

    func testSignOutRemovesAllDomainsThenCredentialsThenRecordLast() async throws {
        let f = Fixture()
        let personal = root(einstein, "personal")
        let project = root(einstein, "project")
        try await f.service.addSpace(personal, displayName: "Personal")
        try await f.service.addSpace(project, displayName: "Project")
        f.recorder.reset()

        try await f.service.signOut(einstein, mode: .removeAll)

        // Both domains gone first, then the credential, then the record last.
        XCTAssertEqual(f.recorder.events, [
            "domain- \(personal.domainIdentifier)",
            "domain- \(project.domainIdentifier)",
            "cred- \(einstein.accountIdentifier)",
            "record- \(einstein.accountIdentifier)",
        ])
    }

    func testSignOutLeavesOtherAccountsUntouched() async throws {
        let f = Fixture()
        let einsteinRoot = root(einstein, "personal")
        let adminRoot = root(admin, nil)
        try await f.service.addSpace(einsteinRoot, displayName: "Personal")
        try await f.service.addSpace(adminRoot, displayName: "All files")

        try await f.service.signOut(einstein, mode: .removeAll)

        let remaining = try await f.service.existingSyncRoots()
        XCTAssertEqual(remaining, [adminRoot])
    }

    // MARK: - Deselect one space: domain only, account survives

    func testRemoveSpaceRemovesOnlyThatDomainAndKeepsAccount() async throws {
        let f = Fixture()
        let personal = root(einstein, "personal")
        let project = root(einstein, "project")
        try await f.service.addSpace(personal, displayName: "Personal")
        try await f.service.addSpace(project, displayName: "Project")
        f.recorder.reset()

        try await f.service.removeSpace(project, mode: .preserveDownloadedUserData)

        // Only the one domain is removed; the credential and record stay (the
        // account may still have other spaces, or legitimately zero).
        XCTAssertEqual(f.recorder.events, ["domain- \(project.domainIdentifier)"])
        let remaining = try await f.service.existingSyncRoots()
        XCTAssertEqual(remaining, [personal])
    }

    // MARK: - Reconcile: apply add/remove, surface orphans, never remove them

    func testReconcileReturnsOrphansButDoesNotRemoveThem() async throws {
        let f = Fixture()
        // A stray domain of an account the registry never knew about.
        let stray = root(admin, nil)
        f.manager.seed(stray)
        f.recorder.reset()

        let plan = try await f.service.reconcile(intent: [], displayNames: [:])

        XCTAssertEqual(plan.orphans, [stray])
        XCTAssertTrue(f.recorder.events.isEmpty, "reconcile must never remove orphans silently")
        let remaining = try await f.service.existingSyncRoots()
        XCTAssertEqual(remaining, [stray], "the orphan domain is still present")
    }

    func testReconcileAppliesAddsAndRemoves() async throws {
        let f = Fixture()
        let personal = root(einstein, "personal")
        let project = root(einstein, "project")
        try await f.service.addSpace(personal, displayName: "Personal")
        f.recorder.reset()

        // Intent wants project, not personal → add project, remove personal.
        _ = try await f.service.reconcile(
            intent: [project],
            displayNames: [project.domainIdentifier: "Project"])

        let remaining = try await f.service.existingSyncRoots()
        XCTAssertEqual(Set(remaining), Set([project]))
    }

    // MARK: - Orphan removal only on confirmation

    func testRemoveOrphansRemovesTheConfirmedDomains() async throws {
        let f = Fixture()
        let stray = root(admin, nil)
        f.manager.seed(stray)
        f.recorder.reset()

        try await f.service.removeOrphans([stray], mode: .preserveDownloadedUserData)

        XCTAssertEqual(f.recorder.events, ["domain- \(stray.domainIdentifier)"])
        let remaining = try await f.service.existingSyncRoots()
        XCTAssertTrue(remaining.isEmpty)
    }

    // MARK: - Single instance

    func testReconcileThrowsAndMutatesNothingWhenAnotherInstanceHoldsTheLock() async throws {
        let f = Fixture(lockAvailable: false)
        let personal = root(einstein, "personal")
        f.manager.seed(personal)
        f.recorder.reset()

        do {
            _ = try await f.service.reconcile(intent: [], displayNames: [:])
            XCTFail("expected a single-instance error")
        } catch {
            XCTAssertTrue(error is SingleInstanceError)
        }
        XCTAssertTrue(f.recorder.events.isEmpty)
    }
}

// MARK: - Fixture and fakes

/// Wires a `DomainService` over recording fakes and keeps references so tests can
/// seed pre-existing domains and inspect the ordered event log.
private final class Fixture {
    let recorder = Recorder()
    let manager: FakeDomainManager
    let service: DomainService

    init(lockAvailable: Bool = true) {
        manager = FakeDomainManager(recorder: recorder)
        service = DomainService(
            registry: RecordingRegistry(recorder: recorder),
            domainManager: manager,
            credentialDeleter: FakeCredentialDeleter(recorder: recorder),
            instanceLock: FakeInstanceLock(available: lockAvailable))
    }
}

/// An ordered event log shared across the fakes so cross-seam ordering is visible.
private final class Recorder: @unchecked Sendable {
    private(set) var events: [String] = []
    func log(_ event: String) { events.append(event) }
    func reset() { events.removeAll() }
}

private final class RecordingRegistry: AccountRegistering, @unchecked Sendable {
    private let recorder: Recorder
    private(set) var accounts: [AccountRecord] = []
    init(recorder: Recorder) { self.recorder = recorder }

    func upsert(_ record: AccountRecord) {
        accounts.removeAll { $0.accountIdentifier == record.accountIdentifier }
        accounts.append(record)
        recorder.log("record+ \(record.accountIdentifier)")
    }
    func remove(accountIdentifier: String) {
        accounts.removeAll { $0.accountIdentifier == accountIdentifier }
        recorder.log("record- \(accountIdentifier)")
    }
}

private final class FakeDomainManager: DomainManaging, @unchecked Sendable {
    private let recorder: Recorder
    private(set) var domains: [SyncRoot] = []
    init(recorder: Recorder) { self.recorder = recorder }

    /// Seed a pre-existing domain with no matching registry record — a leftover
    /// install, the shape orphan handling reacts to.
    func seed(_ syncRoot: SyncRoot) { domains.append(syncRoot) }

    func existingSyncRoots() async throws -> [SyncRoot] { domains }
    func add(_ syncRoot: SyncRoot, displayName: String) async throws {
        domains.append(syncRoot)
        recorder.log("domain+ \(syncRoot.domainIdentifier)")
    }
    func remove(_ syncRoot: SyncRoot, mode: DomainRemovalChoice) async throws {
        domains.removeAll { $0 == syncRoot }
        recorder.log("domain- \(syncRoot.domainIdentifier)")
    }
}

private final class FakeCredentialDeleter: CredentialDeleting, @unchecked Sendable {
    private let recorder: Recorder
    init(recorder: Recorder) { self.recorder = recorder }
    func deleteCredentials(forAccount accountIdentifier: String) async throws {
        recorder.log("cred- \(accountIdentifier)")
    }
}

private final class FakeInstanceLock: InstanceLock, @unchecked Sendable {
    private let available: Bool
    init(available: Bool) { self.available = available }
    func ensureSingleInstance() throws {
        if !available { throw SingleInstanceError.anotherInstanceRunning }
    }
}
