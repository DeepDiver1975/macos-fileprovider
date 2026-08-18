import XCTest
@testable import OwnCloudCore

/// The headless core of the acceptance step library (Task 6.4): matching a parsed
/// Gherkin step's text against registered step patterns and capturing the arguments.
///
/// A step definition binds a Cucumber-expression-style pattern (`{string}` captures
/// a double-quoted run, `{int}` captures an integer) to some action. The *matching*
/// and *argument extraction* are pure text-processing and tested here; the action
/// bodies — which drive the Mac/Docker `BackendAdmin` + `NSFileProviderManager`
/// harness — are the gated half that lives outside this package.
final class StepMatcherTests: XCTestCase {

    /// A `{string}` placeholder captures the text inside double quotes verbatim.
    func testMatchesStringPlaceholder() throws {
        let pattern = try StepPattern("the server has a file {string}")

        let match = pattern.match(#"the server has a file "report.pdf""#)

        XCTAssertEqual(match?.arguments, [.string("report.pdf")])
    }

    /// An `{int}` placeholder captures an integer as a numeric argument.
    func testMatchesIntPlaceholder() throws {
        let pattern = try StepPattern("{int} items are listed")

        let match = pattern.match("500 items are listed")

        XCTAssertEqual(match?.arguments, [.int(500)])
    }

    /// Multiple placeholders capture in order.
    func testMatchesMultiplePlaceholdersInOrder() throws {
        let pattern = try StepPattern(#"the folder {string} contains {int} files"#)

        let match = pattern.match(#"the folder "Big" contains 500 files"#)

        XCTAssertEqual(match?.arguments, [.string("Big"), .int(500)])
    }

    /// A step with no placeholders matches only its exact literal text.
    func testLiteralStepMatchesExactlyAndRejectsOthers() throws {
        let pattern = try StepPattern("the domain is enumerated")

        XCTAssertEqual(pattern.match("the domain is enumerated")?.arguments, [])
        XCTAssertNil(pattern.match("the domain observes changes"))
    }

    /// A non-matching step returns nil (the text shape differs).
    func testNonMatchingStepReturnsNil() throws {
        let pattern = try StepPattern("the server has a file {string}")

        XCTAssertNil(pattern.match("the server has a folder \"Big\""))
    }

    /// Regex metacharacters in the literal parts are matched literally, not as
    /// patterns — a step mentioning "a.b" must not match "axb".
    func testLiteralRegexMetacharactersAreEscaped() throws {
        let pattern = try StepPattern("the item {string} (a.b) is listed")

        XCTAssertNotNil(pattern.match(#"the item "x" (a.b) is listed"#))
        XCTAssertNil(pattern.match(#"the item "x" (axb) is listed"#))
    }

    // MARK: - Registry

    /// The registry finds the single pattern that matches a step and returns its
    /// captured arguments.
    func testRegistryMatchesRegisteredStep() throws {
        let registry = try StepRegistry(patterns: [
            "the server has a file {string}",
            "{int} items are listed",
        ])

        let result = try registry.match(GherkinStep(keyword: .then, text: "3 items are listed"))

        XCTAssertEqual(result.patternText, "{int} items are listed")
        XCTAssertEqual(result.arguments, [.int(3)])
    }

    /// A step no pattern matches is a typed error — an unimplemented step must fail
    /// loudly, never pass silently.
    func testRegistryThrowsOnUndefinedStep() throws {
        let registry = try StepRegistry(patterns: ["the domain is enumerated"])

        XCTAssertThrowsError(
            try registry.match(GherkinStep(keyword: .when, text: "nobody defined this"))
        ) { error in
            XCTAssertEqual(error as? StepMatchError, .undefined("nobody defined this"))
        }
    }

    /// A step that two patterns both match is ambiguous — surfaced as an error so
    /// the step library can't silently pick one. Both patterns below match a step
    /// with two quoted tokens: one binds both as `{string}`, the other pins the
    /// first literally.
    func testRegistryThrowsOnAmbiguousStep() throws {
        let registry = try StepRegistry(patterns: [
            "the item {string} is {string}",
            #"the item "x" is {string}"#,
        ])

        XCTAssertThrowsError(
            try registry.match(GherkinStep(keyword: .then, text: #"the item "x" is "here""#))
        ) { error in
            guard case .ambiguous = (error as? StepMatchError) else {
                return XCTFail("expected .ambiguous, got \(error)")
            }
        }
    }
}
