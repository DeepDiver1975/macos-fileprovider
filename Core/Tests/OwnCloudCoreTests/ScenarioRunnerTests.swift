import XCTest
@testable import OwnCloudCore

/// The headless orchestration half of the acceptance runner (Task 6.4): walking a
/// parsed scenario's steps in order, matching each through the `StepRegistry`, and
/// invoking the action bound to the matched pattern — stopping on the first failure.
///
/// This is pure control flow: the *actions* themselves (which drive the Mac/Docker
/// `BackendAdmin` + `NSFileProviderManager` harness) are injected as closures, so a
/// stub action lets the sequencing, argument-passing, and fail-fast behaviour be
/// proven headlessly. `StepMatcher` made step *selection* pure; this makes step
/// *sequencing* pure — only the action bodies stay gated.
final class ScenarioRunnerTests: XCTestCase {

    /// A scenario whose every step matches a bound action runs them all in order and
    /// reports `.passed`, recording the executed step texts.
    func testRunsAllStepsInOrderAndPasses() async throws {
        let registry = try StepRegistry(patterns: [
            "the server has a file {string}",
            "the domain is enumerated",
            "the item {string} is listed",
        ])
        actor Recorder { var texts: [String] = []; func add(_ t: String) { texts.append(t) } }
        let recorder = Recorder()
        let bindings: [String: ScenarioRunner.Action] = [
            "the server has a file {string}": { _ in await recorder.add("has file") },
            "the domain is enumerated": { _ in await recorder.add("enumerated") },
            "the item {string} is listed": { _ in await recorder.add("listed") },
        ]
        let runner = ScenarioRunner(registry: registry) { bindings[$0] }
        let scenario = GherkinScenario(name: "browse", tags: [], steps: [
            GherkinStep(keyword: .given, text: #"the server has a file "report.pdf""#),
            GherkinStep(keyword: .when, text: "the domain is enumerated"),
            GherkinStep(keyword: .then, text: #"the item "report.pdf" is listed"#),
        ])

        let result = await runner.run(scenario)

        XCTAssertEqual(result.outcome, .passed)
        XCTAssertEqual(result.executedSteps, [
            #"the server has a file "report.pdf""#,
            "the domain is enumerated",
            #"the item "report.pdf" is listed"#,
        ])
        let recorded = await recorder.texts
        XCTAssertEqual(recorded, ["has file", "enumerated", "listed"])
    }

    /// The action for a step receives the arguments captured from the step text, so
    /// it knows what to act on (which filename, how many files).
    func testActionReceivesCapturedArguments() async throws {
        let registry = try StepRegistry(patterns: ["the folder {string} contains {int} files"])
        actor Box { var args: [StepArgument] = []; func set(_ a: [StepArgument]) { args = a } }
        let box = Box()
        let runner = ScenarioRunner(registry: registry) { _ in
            { match in await box.set(match.arguments) }
        }
        let scenario = GherkinScenario(name: "big", tags: [], steps: [
            GherkinStep(keyword: .given, text: #"the folder "Big" contains 500 files"#),
        ])

        let result = await runner.run(scenario)

        XCTAssertEqual(result.outcome, .passed)
        let captured = await box.args
        XCTAssertEqual(captured, [.string("Big"), .int(500)])
    }

    /// When a step's action throws, the run stops at that step: it is reported as the
    /// failing step and no later step runs.
    func testStopsAtFirstFailingStep() async throws {
        struct StepFailure: Error {}
        let registry = try StepRegistry(patterns: [
            "the domain is enumerated",
            "the item {string} is listed",
            "the item {string} is not listed",
        ])
        actor Recorder { var texts: [String] = []; func add(_ t: String) { texts.append(t) } }
        let recorder = Recorder()
        let bindings: [String: ScenarioRunner.Action] = [
            "the domain is enumerated": { _ in await recorder.add("enumerated") },
            "the item {string} is listed": { _ in throw StepFailure() },
            "the item {string} is not listed": { _ in await recorder.add("should not run") },
        ]
        let runner = ScenarioRunner(registry: registry) { bindings[$0] }
        let scenario = GherkinScenario(name: "fails", tags: [], steps: [
            GherkinStep(keyword: .when, text: "the domain is enumerated"),
            GherkinStep(keyword: .then, text: #"the item "gone.txt" is listed"#),
            GherkinStep(keyword: .then, text: #"the item "other.txt" is not listed"#),
        ])

        let result = await runner.run(scenario)

        guard case let .failed(step, _) = result.outcome else {
            return XCTFail("expected .failed, got \(result.outcome)")
        }
        XCTAssertEqual(step, #"the item "gone.txt" is listed"#)
        // Only the first step's action ran; the third never did.
        let recorded = await recorder.texts
        XCTAssertEqual(recorded, ["enumerated"])
        XCTAssertEqual(result.executedSteps, ["the domain is enumerated", #"the item "gone.txt" is listed"#])
    }

    /// A step no registered pattern matches fails the run loudly (an unimplemented
    /// step must never pass silently), and stops the scenario.
    func testUndefinedStepFailsTheRun() async throws {
        let registry = try StepRegistry(patterns: ["the domain is enumerated"])
        let runner = ScenarioRunner(registry: registry) { _ in { _ in } }
        let scenario = GherkinScenario(name: "undef", tags: [], steps: [
            GherkinStep(keyword: .when, text: "nobody defined this"),
            GherkinStep(keyword: .then, text: "the domain is enumerated"),
        ])

        let result = await runner.run(scenario)

        guard case let .failed(step, reason) = result.outcome else {
            return XCTFail("expected .failed, got \(result.outcome)")
        }
        XCTAssertEqual(step, "nobody defined this")
        XCTAssertTrue(reason.lowercased().contains("undefined"), reason)
    }

    /// A step whose pattern matches but has no bound action fails the run — the
    /// catalog listed a pattern the harness never wired, which must surface, not pass.
    func testMatchedButUnboundStepFailsTheRun() async throws {
        let registry = try StepRegistry(patterns: ["the domain is enumerated"])
        // Lookup returns nil for every pattern — nothing is bound.
        let runner = ScenarioRunner(registry: registry) { _ in nil }
        let scenario = GherkinScenario(name: "unbound", tags: [], steps: [
            GherkinStep(keyword: .when, text: "the domain is enumerated"),
        ])

        let result = await runner.run(scenario)

        guard case let .failed(step, reason) = result.outcome else {
            return XCTFail("expected .failed, got \(result.outcome)")
        }
        XCTAssertEqual(step, "the domain is enumerated")
        XCTAssertTrue(reason.lowercased().contains("unbound") || reason.lowercased().contains("no action"), reason)
    }
}
