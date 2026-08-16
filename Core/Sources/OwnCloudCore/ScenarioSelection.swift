import Foundation

/// Tag-based scenario selection for the acceptance suite (progress.md Task 6.6
/// flake policy, and AC-1's per-backend tags).
///
/// Three well-known tags drive selection:
///   * `@quarantine`  — a flaky scenario; excluded from the main suite and run
///                      only by the nightly re-run, so it is isolated but never
///                      silently forgotten.
///   * `@classicOnly` — runs against ownCloud Classic only.
///   * `@ocisOnly`    — runs against oCIS only.
/// An untagged scenario runs in the main suite and against both backends.
public enum ScenarioSelection {

    static let quarantineTag = "quarantine"
    static let classicOnlyTag = "classicOnly"
    static let ocisOnlyTag = "ocisOnly"

    /// Scenarios the every-PR/main suite runs: everything not quarantined.
    public static func mainSuite(_ scenarios: [GherkinScenario]) -> [GherkinScenario] {
        scenarios.filter { !$0.tags.contains(quarantineTag) }
    }

    /// Scenarios the nightly re-run covers: only the quarantined ones.
    public static func quarantined(_ scenarios: [GherkinScenario]) -> [GherkinScenario] {
        scenarios.filter { $0.tags.contains(quarantineTag) }
    }

    /// Scenarios that apply to `backend`: untagged ones run on both; a
    /// backend-only tag restricts to that backend.
    public static func forBackend(_ backend: Backend, _ scenarios: [GherkinScenario]) -> [GherkinScenario] {
        scenarios.filter { scenario in
            let classicOnly = scenario.tags.contains(classicOnlyTag)
            let ocisOnly = scenario.tags.contains(ocisOnlyTag)
            switch backend {
            case .classic: return !ocisOnly
            case .ocis: return !classicOnly
            }
        }
    }
}
