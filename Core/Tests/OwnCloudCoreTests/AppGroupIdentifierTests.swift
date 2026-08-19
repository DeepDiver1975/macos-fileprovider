import XCTest
@testable import OwnCloudCore

/// Pins the **app group identifier** across every place it is declared — the three
/// entitlements files, the extension's `NSExtensionFileProviderDocumentGroup`, and
/// the two Swift constants that open the group container.
///
/// Why this is a test and not a convention (the bug it exists to prevent): on macOS
/// an application group identifier **must** be prefixed with the team id. An
/// unprefixed `group.…` id is accepted by the compiler, by codesign, and by
/// provisioning — and it half-works, which is what made it expensive. The *app*
/// creates `~/Library/Group Containers/group.…` on first write and, as its creator,
/// can keep reading it; the *extension* asks the sandbox for a container it is not
/// entitled to and is denied. Every read then returns `nil` with no error anywhere:
///
///   - `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` → a path
///     the extension cannot open,
///   - `UserDefaults(suiteName:)` → a suite with **zero** of the app's keys.
///
/// In this codebase that silently disabled the whole oCIS refresh path
/// (`FileProviderExtension.makeSession`): with no ``OIDCSessionRecord`` visible it
/// took the refresh-less fallback, so every oCIS mount died 300 seconds after
/// sign-in with `token is expired` in the server log — while looking, from the Mac
/// side, exactly like a TLS/trust problem. Nothing failed loudly, so only a test
/// that reads the declarations can catch it.
///
/// `keychain-access-groups` already used `$(AppIdentifierPrefix)`; only
/// `application-groups` was missed — so this asserts the *shape* of the id, in every
/// file, rather than trusting one to match another.
final class AppGroupIdentifierTests: XCTestCase {

    /// The bare group id, without the team prefix the platform requires.
    private let bareGroupID = "group.com.owncloud.macos.fileprovider"

    /// Xcode expands `$(AppIdentifierPrefix)` to `<TEAMID>.` when it signs, so the
    /// declarations carry the variable rather than a hard-coded team id.
    private let entitlementsPrefix = "$(AppIdentifierPrefix)"

    /// The three entitlements files must all request the **team-prefixed** group.
    /// An unprefixed id here is the defect: it passes signing and denies the
    /// extension at runtime.
    func testEveryEntitlementsFileRequestsTheTeamPrefixedAppGroup() throws {
        for path in [
            "App/SupportingFiles/App.entitlements",
            "FileProviderExtension/SupportingFiles/FileProviderExtension.entitlements",
            "FileProviderUIExtension/SupportingFiles/FileProviderUIExtension.entitlements",
        ] {
            let contents = try Self.repoFile(path)
            XCTAssertTrue(
                contents.contains("<string>\(entitlementsPrefix)\(bareGroupID)</string>"),
                "\(path) must request \(entitlementsPrefix)\(bareGroupID) — an unprefixed app group is denied to the extension at runtime")
        }
    }

    /// `NSExtensionFileProviderDocumentGroup` names the same container, so it must
    /// carry the same prefix. A mismatch here makes
    /// `NSFileProviderManager.add(domain:)` fail with `ProviderNotFound (-2001)`.
    func testDocumentGroupMatchesTheEntitledAppGroup() throws {
        let contents = try Self.repoFile("FileProviderExtension/SupportingFiles/Info.plist")
        XCTAssertTrue(
            contents.contains("<string>\(entitlementsPrefix)\(bareGroupID)</string>"),
            "NSExtensionFileProviderDocumentGroup must name the same team-prefixed group as the entitlement")
    }

    /// The runtime constants must resolve to the prefixed id too — the entitlement
    /// grants access to `<TEAMID>.group.…`, so asking for the bare id gets nothing.
    /// Both processes build it from ``AppGroup/identifier``, so this pins the one
    /// definition rather than two hand-written string literals.
    func testRuntimeIdentifierIsTeamPrefixed() {
        XCTAssertEqual(AppGroup.identifier, "4AP2STM4H5.\(bareGroupID)")
        XCTAssertTrue(AppGroup.identifier.hasSuffix(bareGroupID))
        XCTAssertNotEqual(AppGroup.identifier, bareGroupID,
                          "a bare group id is the bug this test exists to catch")
    }

    /// No source file may open the group container with the bare id — that is the
    /// exact mistake that silently disabled oCIS token refresh.
    func testNoSourceFileUsesTheBareGroupIdentifier() throws {
        for path in [
            "App/Sources/SettingsModel.swift",
            "App/Sources/DevHarnessOCIS.swift",
            "FileProviderExtension/Sources/FileProviderExtension.swift",
        ] {
            let contents = try Self.repoFile(path)
            XCTAssertFalse(
                contents.contains("\"\(bareGroupID)\""),
                "\(path) must use AppGroup.identifier, not the bare \"\(bareGroupID)\"")
        }
    }

    /// Read a repo-relative file, locating the repo from this source file's path so
    /// the test does not depend on the working directory (same approach as
    /// ``AcceptanceStepCatalogTests``).
    private static func repoFile(_ relativePath: String) throws -> String {
        // …/Core/Tests/OwnCloudCoreTests/AppGroupIdentifierTests.swift
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OwnCloudCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Core
            .deletingLastPathComponent()   // repo root
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
