import XCTest
@testable import OwnCloudCore

/// Pins the **Release** entitlements of the File Provider extension: the shipped
/// declaration must drop `com.apple.developer.fileprovider.testing-mode` and keep
/// everything else the extension needs.
///
/// Why this is a unit test. `scripts/make-dmg.sh` already checks the same thing on the
/// *artifact*, by dumping the shipped `.appex`'s entitlements — but that reads the code
/// signature, so it only works on a signed build. The per-PR installer tier
/// (`progress.md` Task 9.7) builds with `SIGNING=none` because no certificate exists on
/// a fork PR, and an unsigned `.appex` is ad-hoc/linker-signed: `codesign -d
/// --entitlements` then exits **0** while writing no file at all. So on a PR nothing
/// inspects the artifact, and this suite covers the *declaration* instead. The two are
/// complementary and neither replaces the other: a test cannot prove what codesign
/// applied, and `make-dmg.sh` cannot run without credentials.
///
/// The bug it exists to prevent has already happened once. The Release file was created
/// by copying the Debug file, and a later change to the Debug file — adding
/// `$(AppIdentifierPrefix)` to the app group — did not reach the copy, so the Release
/// build shipped the bare group id that ``AppGroupIdentifierTests`` was written to
/// catch. Two near-identical declarations drift; the only defence is asserting both.
final class ReleaseEntitlementsTests: XCTestCase {

    private static let debugEntitlements =
        "FileProviderExtension/SupportingFiles/FileProviderExtension.entitlements"
    private static let releaseEntitlements =
        "FileProviderExtension/SupportingFiles/FileProviderExtension-Release.entitlements"

    private static let testingMode = "com.apple.developer.fileprovider.testing-mode"

    /// The entitlement must NOT be in the shipped declaration. Apple grants it only
    /// through a *development* provisioning profile, so a Developer ID profile does not
    /// include it and signing a release fails outright — and it should not ship
    /// regardless, since it exists so the acceptance suite can drive
    /// `NSFileProviderDomain.testingModes` deterministically (AC-3).
    func testReleaseEntitlementsDoNotCarryTestingMode() throws {
        let release = try Self.entitlements(Self.releaseEntitlements)
        XCTAssertNil(
            release[Self.testingMode],
            "\(Self.releaseEntitlements) must not declare \(Self.testingMode) — a Developer ID profile cannot carry it and signing the release fails")
    }

    /// The Debug counterpart, asserted as a **positive control**: without it, deleting
    /// the entitlement from both files would leave the test above passing while the
    /// deterministic test harness silently lost the capability it needs.
    func testDebugEntitlementsStillCarryTestingMode() throws {
        let debug = try Self.entitlements(Self.debugEntitlements)
        XCTAssertEqual(
            debug[Self.testingMode] as? Bool, true,
            "\(Self.debugEntitlements) must keep \(Self.testingMode) — the AC-3 harness drives NSFileProviderDomain.testingModes with it")
    }

    /// Everything the extension cannot work without has to be in **both** files. This is
    /// the drift check: the Release file is a copy, and a change made only to the Debug
    /// file would otherwise ship a crippled extension. `network.client` in particular is
    /// what makes every WebDAV/Graph request possible at all, and its absence would look
    /// like a server problem rather than an entitlements one.
    func testBothFilesDeclareEverythingTheExtensionNeeds() throws {
        for path in [Self.debugEntitlements, Self.releaseEntitlements] {
            let declared = try Self.entitlements(path)

            XCTAssertEqual(declared["com.apple.security.app-sandbox"] as? Bool, true,
                           "\(path) must declare the app sandbox")
            XCTAssertEqual(declared["com.apple.security.network.client"] as? Bool, true,
                           "\(path) must declare network.client — without it every WebDAV/Graph request fails")

            // The team-prefixed forms. An unprefixed app group signs and provisions
            // fine and then denies the extension its container at runtime with no error
            // anywhere; see AppGroupIdentifierTests for the full account.
            XCTAssertEqual(
                declared["com.apple.security.application-groups"] as? [String],
                ["$(AppIdentifierPrefix)group.com.owncloud.macos.fileprovider"],
                "\(path) must request the team-prefixed app group")
            XCTAssertEqual(
                declared["keychain-access-groups"] as? [String],
                ["$(AppIdentifierPrefix)com.owncloud.macos.fileprovider.shared"],
                "\(path) must request the shared keychain group")
        }
    }

    /// The two files differ in exactly one key. Asserted as a set difference rather than
    /// key by key so that a *new* entitlement added to only one of them fails here,
    /// including one nobody has thought of yet.
    func testTheOnlyDifferenceBetweenTheTwoFilesIsTestingMode() throws {
        let debugKeys = Set(try Self.entitlements(Self.debugEntitlements).keys)
        let releaseKeys = Set(try Self.entitlements(Self.releaseEntitlements).keys)

        XCTAssertEqual(debugKeys.subtracting(releaseKeys), [Self.testingMode],
                       "Release may omit only \(Self.testingMode)")
        XCTAssertEqual(releaseKeys.subtracting(debugKeys), [],
                       "Release must not declare anything Debug does not")
    }

    /// The declaration is inert unless `project.yml` points the Release configuration at
    /// it — the file could be perfect and still never be used. Scoped to the
    /// `FileProviderExtension` target's own block, because a match anywhere in the file
    /// would also be satisfied by, say, a comment in another target.
    func testProjectYmlMapsTheReleaseConfigToTheReleaseFile() throws {
        let manifest = try Self.repoFile("project.yml")

        guard let targetStart = manifest.range(of: "\n  FileProviderExtension:\n"),
              let nextTarget = manifest.range(of: "\n  FileProviderUIExtension:\n") else {
            return XCTFail("could not locate the FileProviderExtension target block in project.yml")
        }
        let block = manifest[targetStart.upperBound..<nextTarget.lowerBound]

        XCTAssertTrue(
            block.contains("Release:"),
            "project.yml's FileProviderExtension target needs a Release config override")
        XCTAssertTrue(
            block.contains("CODE_SIGN_ENTITLEMENTS: \(Self.releaseEntitlements)"),
            "project.yml must map the Release config to \(Self.releaseEntitlements), or the Release build signs with the Debug entitlements and carries testing-mode")
    }

    // MARK: - Reading the declarations

    /// Parse an entitlements file into its key/value pairs.
    ///
    /// **Parsed, not string-searched** — and this is not a stylistic preference. Both
    /// files carry a comment block explaining the testing-mode entitlement, so the
    /// literal string `com.apple.developer.fileprovider.testing-mode` appears once in
    /// the Debug file and *twice* in the Release file that deliberately omits it. A
    /// `contents.contains(…)` assertion in the style of ``AppGroupIdentifierTests``
    /// would therefore be exactly inverted here. Same family of trap as the two already
    /// recorded under `progress.md` Task 9.4: `plutil -extract` reading reverse-DNS keys
    /// as keypaths, and `name = <Config>;` sitting at the end of a `.pbxproj` block.
    private static func entitlements(_ relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repoURL(relativePath))
        let parsed = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil)
        guard let dictionary = parsed as? [String: Any] else {
            throw XCTSkip("\(relativePath) is not a plist dictionary")
        }
        return dictionary
    }

    private static func repoFile(_ relativePath: String) throws -> String {
        try String(contentsOf: repoURL(relativePath), encoding: .utf8)
    }

    /// Locate a repo-relative file from this source file's own path, so the tests do not
    /// depend on the working directory (same approach as ``AppGroupIdentifierTests``).
    private static func repoURL(_ relativePath: String) -> URL {
        // …/Core/Tests/OwnCloudCoreTests/ReleaseEntitlementsTests.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OwnCloudCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Core
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(relativePath)
    }
}
