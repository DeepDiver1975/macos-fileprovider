import XCTest
@testable import OwnCloudCore

/// Task 7.10: the Phase 7 acceptance scenarios (`test/features/configuration.feature`),
/// joining the Phase 5 lifecycle group per AC-5. The full runner is Mac + Docker
/// gated, but the scenarios themselves are a headless artifact — they must parse
/// with the tested `GherkinParser`, carry the AC-1 backend tags where behaviour
/// differs, and cover the six flows the task names. Task 7.6 is not done until the
/// refresh-race scenario exists (asserted below).
final class ConfigurationFeatureTests: XCTestCase {

    private func loadFeature() throws -> GherkinFeature {
        // The feature file lives at repo-root test/features; locate it relative to
        // this source file so the test is independent of the working directory.
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()  // OwnCloudCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // Core
            .deletingLastPathComponent()  // repo root
        let featureURL = repoRoot
            .appendingPathComponent("test/features/configuration.feature")
        let source = try String(contentsOf: featureURL, encoding: .utf8)
        return try GherkinParser().parse(source)
    }

    func testFeatureParsesAndIsTaggedConfiguration() throws {
        let feature = try loadFeature()
        XCTAssertTrue(feature.tags.contains("configuration"),
                      "the feature carries the @configuration group tag")
        XCTAssertFalse(feature.scenarios.isEmpty)
    }

    func testCoversAllSixRequiredFlows() throws {
        let names = try loadFeature().scenarios.map { $0.name.lowercased() }
        func hasScenario(matching needles: [String]) -> Bool {
            names.contains { name in needles.allSatisfy { name.contains($0) } }
        }
        // The six flows Task 7.10 enumerates.
        XCTAssertTrue(hasScenario(matching: ["select", "space"]), "select a space → domain appears")
        XCTAssertTrue(hasScenario(matching: ["deselect", "preserv"]), "deselect preserving downloads")
        XCTAssertTrue(hasScenario(matching: ["deselect", "remove"]), "deselect with removeAll")
        XCTAssertTrue(hasScenario(matching: ["sign out"]), "sign out with two spaces")
        XCTAssertTrue(hasScenario(matching: ["orphan"]), "orphan detection after registry wipe")
        XCTAssertTrue(hasScenario(matching: ["refresh", "race"]), "the refresh race (Task 7.6 gate)")
    }

    func testSpaceSelectionScenariosAreTaggedOCISOnly() throws {
        // AC-1: space selection is an oCIS capability, so those scenarios carry
        // @ocisOnly with the difference stated, never a silent skip.
        let feature = try loadFeature()
        let selection = feature.scenarios.first { $0.name.lowercased().contains("select a space") }
        let unwrapped = try XCTUnwrap(selection, "the select-a-space scenario exists")
        XCTAssertTrue(unwrapped.tags.contains("ocisOnly"),
                      "space selection is oCIS-only per AC-1")
    }

    func testRefreshRaceScenarioKeepsBothSpacesAuthenticated() throws {
        // Task 7.6's end-to-end gate: two spaces, token forced to expire, both stay
        // authenticated. Assert the scenario's shape so it can't silently degrade.
        let feature = try loadFeature()
        let race = try XCTUnwrap(
            feature.scenarios.first { $0.name.lowercased().contains("refresh race") })
        let stepText = race.steps.map { $0.text.lowercased() }.joined(separator: " | ")
        XCTAssertTrue(stepText.contains("expire"), "the token is forced to expire")
        XCTAssertTrue(stepText.contains("authenticated"), "both spaces stay authenticated")
    }
}
