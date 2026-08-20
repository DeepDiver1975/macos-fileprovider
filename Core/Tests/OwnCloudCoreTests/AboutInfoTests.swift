import XCTest
@testable import OwnCloudCore

/// Issue #18: the About window's content lives in a headlessly tested core type
/// for the same reason the settings window's does (Task 7.8) — the SwiftUI layer
/// stays a renderer, and the wording plus the support-relevant version rows are
/// covered by the Linux-buildable suite.
final class AboutInfoTests: XCTestCase {

    /// The versions the app reads from its own and its extensions' bundles.
    private let bundled = AboutInfo.BundleVersions(
        appVersion: "1.2.3",
        appBuild: "45",
        fileProviderExtension: BundleVersion(version: "1.2.3", build: "45"),
        fileProviderUIExtension: BundleVersion(version: "1.2.3", build: "45")
    )

    // MARK: - Identity

    func testNameAndVersionAreRenderedForDisplay() {
        let about = AboutInfo.make(versions: bundled, osVersion: "26.0", year: 2026)

        XCTAssertEqual(about.applicationName, "ownCloud File Provider")
        XCTAssertEqual(about.versionSummary, "Version 1.2.3 (45)")
    }

    func testCopyrightNamesOwnCloudAndTheGivenYear() {
        let about = AboutInfo.make(versions: bundled, osVersion: "26.0", year: 2031)

        // The year is injected rather than read from the clock so the string is
        // deterministic in tests and identical on every machine.
        XCTAssertEqual(about.copyright, "© 2031 ownCloud GmbH")
    }

    // MARK: - Detail rows

    func testDetailRowsCarryTheVersionsSupportAsksFor() {
        let about = AboutInfo.make(versions: bundled, osVersion: "26.0", year: 2026)

        // A bug report needs to distinguish the app from the two extensions, which
        // load out-of-process and can be stale relative to it.
        let rows = Dictionary(uniqueKeysWithValues: about.detailRows.map { ($0.label, $0.value) })
        XCTAssertEqual(rows["File Provider Extension"], "1.2.3 (45)")
        XCTAssertEqual(rows["File Provider UI Extension"], "1.2.3 (45)")
        XCTAssertEqual(rows["macOS"], "26.0")
    }

    func testDetailRowsKeepAStableOrder() {
        let about = AboutInfo.make(versions: bundled, osVersion: "26.0", year: 2026)

        XCTAssertEqual(about.detailRows.map(\.label),
                       ["File Provider Extension", "File Provider UI Extension", "macOS"])
    }

    /// The rendered rows describe the *running bundles*. A row sourced from a
    /// hardcoded Swift constant cannot, because a release stamps its version into the
    /// Info.plists via MARKETING_VERSION and never touches the source — so at v1.2.0
    /// such a row would still read the compiled-in value and quietly contradict the
    /// version directly above it.
    func testNoRowIsSourcedFromTheCompiledInPackageVersion() {
        let about = AboutInfo.make(versions: bundled, osVersion: "26.0", year: 2026)

        XCTAssertFalse(about.detailRows.contains { $0.value == OwnCloudCore.version },
                       "no About row may report the hardcoded package version: \(about.detailRows)")
    }

    /// An extension bundle that cannot be read must degrade to a legible
    /// placeholder: the About window is what a user opens *because* something is
    /// wrong, so it has to render when an extension is missing or unloadable.
    func testUnreadableExtensionVersionRendersAsUnavailableRatherThanVanishing() {
        let partial = AboutInfo.BundleVersions(
            appVersion: "1.2.3",
            appBuild: "45",
            fileProviderExtension: nil,
            fileProviderUIExtension: BundleVersion(version: "1.2.3", build: "45")
        )

        let about = AboutInfo.make(versions: partial, osVersion: "26.0", year: 2026)

        let rows = Dictionary(uniqueKeysWithValues: about.detailRows.map { ($0.label, $0.value) })
        XCTAssertEqual(rows["File Provider Extension"], AboutInfo.unavailableValue)
        // The row is still present, and the readable sibling is unaffected.
        XCTAssertEqual(about.detailRows.count, 3)
        XCTAssertEqual(rows["File Provider UI Extension"], "1.2.3 (45)")
    }

    // MARK: - App version for other surfaces

    /// The settings pane shows a bare version too, and it has to be the same number
    /// the About window and the release artifact carry — so it comes from here rather
    /// than from a second source that could drift.
    func testAppVersionDisplayMatchesWhatTheBundleReports() {
        let about = AboutInfo.make(versions: bundled, osVersion: "26.0", year: 2026)

        XCTAssertEqual(about.appVersionDisplay, "1.2.3 (45)")
        // Same value the summary renders, minus the "Version " prefix.
        XCTAssertEqual(about.versionSummary, "Version \(about.appVersionDisplay)")
    }

    func testAppVersionDisplayFallsBackWhenTheBundleIsUnreadable() {
        let unknown = AboutInfo.BundleVersions(
            appVersion: nil, appBuild: nil,
            fileProviderExtension: nil, fileProviderUIExtension: nil
        )

        let about = AboutInfo.make(versions: unknown, osVersion: "26.0", year: 2026)

        XCTAssertEqual(about.appVersionDisplay, AboutInfo.unavailableValue)
    }

    // MARK: - Version formatting

    func testBundleVersionOmitsTheBuildWhenItAddsNothing() {
        // A build identical to the marketing version would render "1.2.3 (1.2.3)".
        XCTAssertEqual(BundleVersion(version: "1.2.3", build: "1.2.3").displayString, "1.2.3")
        XCTAssertEqual(BundleVersion(version: "1.2.3", build: "45").displayString, "1.2.3 (45)")
    }

    func testBundleVersionToleratesAMissingBuildNumber() {
        XCTAssertEqual(BundleVersion(version: "1.2.3", build: nil).displayString, "1.2.3")
        XCTAssertEqual(BundleVersion(version: "1.2.3", build: "").displayString, "1.2.3")
    }

    func testAppVersionSummaryFallsBackWhenTheBundleIsUnreadable() {
        // Reading the app's own Info.plist should never fail, but the type takes
        // strings, so it must not render "Version  ()" if it ever does.
        let unknown = AboutInfo.BundleVersions(
            appVersion: nil, appBuild: nil,
            fileProviderExtension: nil, fileProviderUIExtension: nil
        )

        let about = AboutInfo.make(versions: unknown, osVersion: "26.0", year: 2026)

        XCTAssertEqual(about.versionSummary, "Version \(AboutInfo.unavailableValue)")
    }

    // MARK: - Links

    func testLinksPointAtOwnCloudAndTheIssueTracker() {
        let about = AboutInfo.make(versions: bundled, osVersion: "26.0", year: 2026)

        XCTAssertEqual(about.links.map(\.title), ["Website", "Documentation", "Report an Issue"])
        let hosts = about.links.map { $0.url.host ?? "" }
        XCTAssertEqual(hosts, ["owncloud.com", "doc.owncloud.com", "github.com"])
        XCTAssertTrue(about.links.allSatisfy { $0.url.scheme == "https" },
                      "every link is https: \(about.links.map { $0.url })")
        XCTAssertEqual(about.links.last?.url.path, "/DeepDiver1975/macos-fileprovider/issues")
    }
}
