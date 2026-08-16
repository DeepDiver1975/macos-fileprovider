import Foundation

/// A step keyword. `And`/`But` inherit the previous step's effective keyword.
public enum StepKeyword: String, Sendable, Equatable {
    case given = "Given"
    case when = "When"
    case then = "Then"
}

/// One parsed step: an effective keyword plus the step text (keyword removed).
public struct GherkinStep: Sendable, Equatable {
    public let keyword: StepKeyword
    public let text: String
    public init(keyword: StepKeyword, text: String) {
        self.keyword = keyword
        self.text = text
    }
}

/// A parsed scenario (or scenario outline). Background steps are already
/// prepended. For an outline, `examples` holds the rows; `expanded()` produces
/// one concrete scenario per row with `<placeholders>` substituted.
public struct GherkinScenario: Sendable, Equatable {
    public let name: String
    public let tags: [String]
    public let steps: [GherkinStep]
    /// Example rows as column→value dictionaries (empty for a plain scenario).
    public let examples: [[String: String]]

    public init(name: String, tags: [String], steps: [GherkinStep], examples: [[String: String]] = []) {
        self.name = name
        self.tags = tags
        self.steps = steps
        self.examples = examples
    }

    /// Expand an outline into concrete scenarios, one per example row. A plain
    /// scenario (no examples) returns itself.
    public func expanded() -> [GherkinScenario] {
        guard !examples.isEmpty else { return [self] }
        return examples.map { row in
            let substituted = steps.map { step in
                GherkinStep(keyword: step.keyword, text: Self.substitute(step.text, row: row))
            }
            return GherkinScenario(name: name, tags: tags, steps: substituted, examples: [])
        }
    }

    private static func substitute(_ text: String, row: [String: String]) -> String {
        var result = text
        for (key, value) in row {
            result = result.replacingOccurrences(of: "<\(key)>", with: value)
        }
        return result
    }
}

/// A parsed feature.
public struct GherkinFeature: Sendable, Equatable {
    public let name: String
    public let tags: [String]
    public let scenarios: [GherkinScenario]
}

public enum GherkinParseError: Error, Equatable {
    case missingFeature
}

/// A minimal Gherkin parser covering the subset the acceptance `.feature` files
/// use: feature/scenario/scenario-outline, background, tags, `And`/`But`
/// continuation, and an examples table. Deliberately small — just enough to keep
/// the feature files diff-comparable with the desktop client's wording
/// (progress.md Task 6.4).
public struct GherkinParser {

    public init() {}

    public func parse(_ source: String) throws -> GherkinFeature {
        var featureName: String?
        var featureTags: [String] = []
        var scenarios: [GherkinScenario] = []

        var backgroundSteps: [GherkinStep] = []

        // Pending tags accumulated from `@tag` lines, applied to the next block.
        var pendingTags: [String] = []
        var lastKeyword: StepKeyword = .given

        // Current scenario being built.
        var curName: String?
        var curTags: [String] = []
        var curSteps: [GherkinStep] = []
        var curExamples: [[String: String]] = []
        var inBackground = false

        // Examples-table state.
        var exampleHeaders: [String]?
        var collectingExamples = false

        func flushScenario() {
            guard let name = curName else { return }
            scenarios.append(GherkinScenario(name: name, tags: curTags, steps: curSteps, examples: curExamples))
            curName = nil
            curTags = []
            curSteps = []
            curExamples = []
        }

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("@") {
                pendingTags.append(contentsOf: line.split(separator: " ").map { String($0.dropFirst()) })
                continue
            }

            if line.hasPrefix("Feature:") {
                featureName = value(after: "Feature:", in: line)
                featureTags = pendingTags; pendingTags = []
                continue
            }

            if line.hasPrefix("Background:") {
                inBackground = true
                collectingExamples = false
                continue
            }

            if line.hasPrefix("Scenario Outline:") || line.hasPrefix("Scenario:") {
                flushScenario()
                inBackground = false
                collectingExamples = false
                exampleHeaders = nil
                let keyword = line.hasPrefix("Scenario Outline:") ? "Scenario Outline:" : "Scenario:"
                curName = value(after: keyword, in: line)
                curTags = pendingTags; pendingTags = []
                curSteps = backgroundSteps        // prepend background
                lastKeyword = .given
                continue
            }

            if line.hasPrefix("Examples:") {
                collectingExamples = true
                exampleHeaders = nil
                continue
            }

            if collectingExamples, line.hasPrefix("|") {
                let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if exampleHeaders == nil {
                    exampleHeaders = cells
                } else if let headers = exampleHeaders {
                    var row: [String: String] = [:]
                    for (index, header) in headers.enumerated() where index < cells.count {
                        row[header] = cells[index]
                    }
                    curExamples.append(row)
                }
                continue
            }

            // Otherwise: a step line.
            if let step = parseStep(line, lastKeyword: &lastKeyword) {
                if inBackground {
                    backgroundSteps.append(step)
                } else if curName != nil {
                    curSteps.append(step)
                }
            }
        }
        flushScenario()

        guard let name = featureName else { throw GherkinParseError.missingFeature }
        return GherkinFeature(name: name, tags: featureTags, scenarios: scenarios)
    }

    private func parseStep(_ line: String, lastKeyword: inout StepKeyword) -> GherkinStep? {
        let keywords: [(String, StepKeyword?)] = [
            ("Given ", .given), ("When ", .when), ("Then ", .then),
            ("And ", nil), ("But ", nil),
        ]
        for (prefix, keyword) in keywords where line.hasPrefix(prefix) {
            let text = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            let effective = keyword ?? lastKeyword
            lastKeyword = effective
            return GherkinStep(keyword: effective, text: text)
        }
        return nil
    }

    private func value(after keyword: String, in line: String) -> String {
        String(line.dropFirst(keyword.count)).trimmingCharacters(in: .whitespaces)
    }
}
