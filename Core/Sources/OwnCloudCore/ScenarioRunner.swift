import Foundation

/// Runs a parsed acceptance scenario (Task 6.4): walks its steps in order, matches
/// each through a ``StepRegistry``, and invokes the action bound to the matched
/// pattern — stopping at the first step that fails.
///
/// This is the pure orchestration half of the acceptance runner. The *actions* — the
/// bodies that provision a fixture via `BackendAdmin`, add a domain via
/// `NSFileProviderManager`, or assert materialisation — are injected as closures, so
/// the sequencing, argument-passing, and fail-fast behaviour are proven headlessly;
/// only the action bodies themselves live in the Mac/Docker-gated harness.
///
/// A step fails the run in three ways, all surfaced (never swallowed): its text
/// matches no pattern (``StepMatchError/undefined(_:)`` — an unimplemented step), its
/// pattern has no bound action (the catalog listed a pattern the harness never
/// wired), or its action throws.
public struct ScenarioRunner: Sendable {

    /// The behaviour bound to a step pattern, receiving the ``StepMatch`` so it can
    /// read the captured arguments. Throwing signals the step failed.
    public typealias Action = @Sendable (StepMatch) async throws -> Void

    /// Resolves a matched pattern's text to its bound action, or `nil` if unbound.
    public typealias ActionLookup = @Sendable (String) -> Action?

    /// How a scenario run ended.
    public enum Outcome: Sendable, Equatable {
        case passed
        /// The run stopped at `step` (its full text) for `reason`.
        case failed(step: String, reason: String)
    }

    /// The result of a run: the outcome plus the step texts that actually executed
    /// (including the failing one, so a report can show how far it got).
    public struct Result: Sendable, Equatable {
        public let outcome: Outcome
        public let executedSteps: [String]

        public init(outcome: Outcome, executedSteps: [String]) {
            self.outcome = outcome
            self.executedSteps = executedSteps
        }
    }

    private let registry: StepRegistry
    private let lookup: ActionLookup

    public init(registry: StepRegistry, lookup: @escaping ActionLookup) {
        self.registry = registry
        self.lookup = lookup
    }

    /// Run every step of `scenario` in order, short-circuiting on the first failure.
    public func run(_ scenario: GherkinScenario) async -> Result {
        var executed: [String] = []
        for step in scenario.steps {
            executed.append(step.text)

            let match: StepMatch
            do {
                match = try registry.match(step)
            } catch {
                return Result(
                    outcome: .failed(step: step.text, reason: describe(error)),
                    executedSteps: executed)
            }

            guard let action = lookup(match.patternText) else {
                return Result(
                    outcome: .failed(
                        step: step.text,
                        reason: "no action bound (unbound pattern \(match.patternText.debugDescription))"),
                    executedSteps: executed)
            }

            do {
                try await action(match)
            } catch {
                return Result(
                    outcome: .failed(step: step.text, reason: "\(error)"),
                    executedSteps: executed)
            }
        }
        return Result(outcome: .passed, executedSteps: executed)
    }

    /// A human-readable reason for a match failure, keeping the `undefined`/`ambiguous`
    /// vocabulary the ``StepMatchError`` cases carry so a report can distinguish them.
    private func describe(_ error: Error) -> String {
        switch error as? StepMatchError {
        case .undefined(let text):
            return "undefined step: \(text.debugDescription)"
        case .ambiguous(let step, let patterns):
            return "ambiguous step \(step.debugDescription) matched \(patterns)"
        case nil:
            return "\(error)"
        }
    }
}
