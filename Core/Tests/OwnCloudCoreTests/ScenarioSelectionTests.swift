import XCTest
@testable import OwnCloudCore

/// Task 6.6 (flake policy): the `@quarantine` tag partitions a feature's
/// scenarios. The main suite runs everything *not* quarantined; the nightly
/// re-run runs *only* the quarantined ones, so a flaky scenario is isolated
/// without being forgotten. The `@classicOnly` / `@ocisOnly` backend tags
/// (AC-1) select which backend a scenario runs against.
///
/// The tag *filtering* is pure list processing and is exercised fully here;
/// actually executing the selected scenarios is Mac + Docker gated.
final class ScenarioSelectionTests: XCTestCase {

    private func feature() throws -> GherkinFeature {
        let source = """
        @enumeration
        Feature: F

          @classicOnly
          Scenario: only classic
            Given x

          @quarantine
          Scenario: flaky one
            Given x

          @ocisOnly @quarantine
          Scenario: flaky ocis
            Given x

          Scenario: plain
            Given x
        """
        return try GherkinParser().parse(source)
    }

    func testMainSuiteExcludesQuarantined() throws {
        let selected = ScenarioSelection.mainSuite(try feature().scenarios)
        XCTAssertEqual(selected.map(\.name), ["only classic", "plain"])
    }

    func testQuarantineReRunTakesOnlyQuarantined() throws {
        let selected = ScenarioSelection.quarantined(try feature().scenarios)
        XCTAssertEqual(selected.map(\.name), ["flaky one", "flaky ocis"])
    }

    func testBackendFilterKeepsUntaggedAndMatchingBackend() throws {
        let classic = ScenarioSelection.forBackend(.classic, try feature().scenarios)
        // untagged "plain"/"flaky one" run on both; "only classic" runs on classic;
        // "flaky ocis" is @ocisOnly so it is excluded from classic.
        XCTAssertEqual(classic.map(\.name), ["only classic", "flaky one", "plain"])
    }

    func testBackendFilterExcludesOtherBackendOnly() throws {
        let ocis = ScenarioSelection.forBackend(.ocis, try feature().scenarios)
        XCTAssertEqual(ocis.map(\.name), ["flaky one", "flaky ocis", "plain"])
    }
}
