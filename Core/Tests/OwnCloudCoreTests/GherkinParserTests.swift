import XCTest
@testable import OwnCloudCore

/// Task 6.4: a small Gherkin parser for the acceptance `.feature` files.
///
/// The step *library* (mapping steps onto the Task 6.3 harness) and running the
/// scenarios against a live domain are Mac + Docker gated. The parser itself is
/// pure text processing and is exercised fully here — it is what keeps the
/// `.feature` files diff-comparable with the desktop client's wording.
final class GherkinParserTests: XCTestCase {

    private let feature = """
    # a leading comment
    @enumeration
    Feature: Syncing all files and folders from the server
      Items must appear unmaterialised.

      Background:
        Given a signed-in domain

      @classicOnly
      Scenario: Items appear without being downloaded
        Given the server has a file "report.pdf"
        When the domain is enumerated
        Then the item "report.pdf" is listed
        And the item "report.pdf" is not materialised

      Scenario Outline: Various file types round-trip
        When a file named "<name>" is created locally
        Then the server has a file "<name>"

        Examples:
          | name       |
          | photo.jpg  |
          | notes.txt  |
    """

    func testParsesFeatureNameAndTags() throws {
        let parsed = try GherkinParser().parse(feature)
        XCTAssertEqual(parsed.name, "Syncing all files and folders from the server")
        XCTAssertEqual(parsed.tags, ["enumeration"])
    }

    func testParsesTwoScenarios() throws {
        let parsed = try GherkinParser().parse(feature)
        XCTAssertEqual(parsed.scenarios.count, 2)
        XCTAssertEqual(parsed.scenarios[0].name, "Items appear without being downloaded")
        XCTAssertEqual(parsed.scenarios[1].name, "Various file types round-trip")
    }

    func testScenarioCarriesItsOwnTags() throws {
        let parsed = try GherkinParser().parse(feature)
        XCTAssertEqual(parsed.scenarios[0].tags, ["classicOnly"])
        XCTAssertTrue(parsed.scenarios[1].tags.isEmpty)
    }

    func testBackgroundStepsArePrependedToEachScenario() throws {
        let parsed = try GherkinParser().parse(feature)
        // "Given a signed-in domain" leads every scenario's steps.
        XCTAssertEqual(parsed.scenarios[0].steps.first?.text, "a signed-in domain")
        XCTAssertEqual(parsed.scenarios[0].steps.first?.keyword, .given)
    }

    func testStepKeywordsAndTextParsed() throws {
        let parsed = try GherkinParser().parse(feature)
        let steps = parsed.scenarios[0].steps
        // background + 4 scenario steps
        XCTAssertEqual(steps.count, 5)
        XCTAssertEqual(steps[1], GherkinStep(keyword: .given, text: "the server has a file \"report.pdf\""))
        XCTAssertEqual(steps[2], GherkinStep(keyword: .when, text: "the domain is enumerated"))
        XCTAssertEqual(steps[3], GherkinStep(keyword: .then, text: "the item \"report.pdf\" is listed"))
        // "And" inherits the previous keyword (Then).
        XCTAssertEqual(steps[4], GherkinStep(keyword: .then, text: "the item \"report.pdf\" is not materialised"))
    }

    func testScenarioOutlineExpandsExamples() throws {
        let parsed = try GherkinParser().parse(feature)
        let outline = parsed.scenarios[1]
        // Two example rows → two concrete expansions.
        XCTAssertEqual(outline.examples.count, 2)

        let expanded = outline.expanded()
        XCTAssertEqual(expanded.count, 2)
        XCTAssertEqual(expanded[0].steps[1].text, "a file named \"photo.jpg\" is created locally")
        XCTAssertEqual(expanded[1].steps[1].text, "a file named \"notes.txt\" is created locally")
    }

    func testThrowsWhenNoFeatureLine() {
        XCTAssertThrowsError(try GherkinParser().parse("Scenario: orphan\n  Given x"))
    }
}
