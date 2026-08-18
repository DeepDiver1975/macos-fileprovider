import XCTest
@testable import OwnCloudCore

/// Proves the acceptance step catalog (Task 6.4) covers every step actually written
/// in the committed `.feature` files, and that each is matched unambiguously.
///
/// This is the headless guarantee behind the step library: a scenario can only run
/// if every one of its steps binds to exactly one definition. The *actions* those
/// definitions trigger are the Mac/Docker-gated half (they drive `BackendAdmin` +
/// `NSFileProviderManager`), but the mapping from step text → definition is pure and
/// verified here against the real feature wording — so an undefined or ambiguous
/// step is caught in the headless loop, not at runtime on the Mac.
final class AcceptanceStepCatalogTests: XCTestCase {

    /// Every step in every committed feature file matches exactly one catalog
    /// pattern. A failure here means either a scenario used wording no definition
    /// covers, or two definitions overlap — both must be fixed before the runner
    /// (Task 6.4 Mac half) could execute the scenario.
    func testCatalogMatchesEveryStepInTheFeatureFiles() throws {
        let registry = try AcceptanceStepCatalog.registry()
        let parser = GherkinParser()

        let featureDir = Self.featuresDirectory()
        let featureFiles = try FileManager.default
            .contentsOfDirectory(at: featureDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "feature" }
        XCTAssertFalse(featureFiles.isEmpty, "no .feature files found at \(featureDir.path)")

        for file in featureFiles {
            let feature = try parser.parse(String(contentsOf: file, encoding: .utf8))
            // Expand outlines so example-substituted steps are checked too.
            for scenario in feature.scenarios.flatMap({ $0.expanded() }) {
                for step in scenario.steps {
                    XCTAssertNoThrow(
                        try registry.match(step),
                        "unmatched/ambiguous step \(step.text.debugDescription) "
                            + "in \(file.lastPathComponent) / \(scenario.name)")
                }
            }
        }
    }

    /// The catalog itself compiles (all patterns are valid) and is non-empty.
    func testCatalogIsNonEmptyAndCompiles() throws {
        let patterns = AcceptanceStepCatalog.patterns
        XCTAssertFalse(patterns.isEmpty)
        XCTAssertNoThrow(try AcceptanceStepCatalog.registry())
    }

    /// Locate the repo's `test/features` directory relative to this source file, so
    /// the test does not depend on the working directory.
    private static func featuresDirectory() -> URL {
        // …/Core/Tests/OwnCloudCoreTests/AcceptanceStepCatalogTests.swift
        // → repo root is four levels up from this file's directory.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OwnCloudCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Core
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("test/features")
    }
}
