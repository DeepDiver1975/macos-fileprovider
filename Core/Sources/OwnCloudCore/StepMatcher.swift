import Foundation

/// A value captured from a Gherkin step by a `{string}`/`{int}` placeholder
/// (Task 6.4). The step library's action bodies read these to know what to do —
/// e.g. which filename to upload, how many files to expect.
public enum StepArgument: Equatable, Sendable {
    case string(String)
    case int(Int)
}

/// Why a step could not be matched against the registered patterns.
public enum StepMatchError: Error, Equatable {
    /// No registered pattern matched the step text — an unimplemented step, which
    /// must fail loudly rather than pass silently.
    case undefined(String)
    /// More than one registered pattern matched, so the step library can't pick a
    /// single action deterministically. Carries the step text and the clashing
    /// pattern strings.
    case ambiguous(step: String, patterns: [String])
}

/// The result of matching a step against one pattern: the pattern that matched and
/// the arguments captured from the step, in order.
public struct StepMatch: Equatable, Sendable {
    public let patternText: String
    public let arguments: [StepArgument]

    public init(patternText: String, arguments: [StepArgument]) {
        self.patternText = patternText
        self.arguments = arguments
    }
}

/// A Cucumber-expression-style step pattern compiled to an anchored regex.
///
/// `{string}` matches a double-quoted run and captures its contents; `{int}`
/// matches an optionally-signed integer and captures it. Everything else is literal
/// text, regex-escaped so metacharacters in the wording (`.`, `(`, `)`) match
/// themselves. Matching is pure — no I/O — so the whole step-selection layer is
/// tested headlessly; only the action a match triggers is Mac/Docker-gated.
public struct StepPattern: Sendable {

    public let text: String
    private let regex: NSRegularExpression
    /// The placeholder kinds, in order, so a match can decode each capture group.
    private let placeholders: [Placeholder]

    private enum Placeholder {
        case string
        case int
    }

    public init(_ text: String) throws {
        self.text = text
        var placeholders: [Placeholder] = []
        var regexParts: [String] = ["^"]

        // Walk the pattern, replacing each {string}/{int} token with a capture
        // group and escaping the literal spans in between.
        var remainder = Substring(text)
        while let open = remainder.firstIndex(of: "{") {
            let literal = String(remainder[remainder.startIndex..<open])
            regexParts.append(NSRegularExpression.escapedPattern(for: literal))

            guard let close = remainder[open...].firstIndex(of: "}") else {
                // A stray '{' with no '}' — treat the rest as literal text.
                regexParts.append(NSRegularExpression.escapedPattern(for: String(remainder[open...])))
                remainder = remainder[remainder.endIndex...]
                break
            }
            let token = String(remainder[remainder.index(after: open)..<close])
            switch token {
            case "string":
                placeholders.append(.string)
                regexParts.append("\"([^\"]*)\"")
            case "int":
                placeholders.append(.int)
                regexParts.append("(-?\\d+)")
            default:
                // An unknown {token} is matched literally, braces included.
                regexParts.append(NSRegularExpression.escapedPattern(for: "{\(token)}"))
            }
            remainder = remainder[remainder.index(after: close)...]
        }
        regexParts.append(NSRegularExpression.escapedPattern(for: String(remainder)))
        regexParts.append("$")

        self.placeholders = placeholders
        self.regex = try NSRegularExpression(pattern: regexParts.joined())
    }

    /// Match `stepText` against this pattern, returning the captured arguments, or
    /// `nil` if it does not match.
    public func match(_ stepText: String) -> StepMatch? {
        let range = NSRange(stepText.startIndex..<stepText.endIndex, in: stepText)
        guard let result = regex.firstMatch(in: stepText, range: range) else { return nil }

        var arguments: [StepArgument] = []
        for (index, placeholder) in placeholders.enumerated() {
            // Capture group 0 is the whole match; groups 1... are the placeholders.
            let groupRange = result.range(at: index + 1)
            guard groupRange.location != NSNotFound,
                  let swiftRange = Range(groupRange, in: stepText) else {
                return nil
            }
            let captured = String(stepText[swiftRange])
            switch placeholder {
            case .string:
                arguments.append(.string(captured))
            case .int:
                guard let value = Int(captured) else { return nil }
                arguments.append(.int(value))
            }
        }
        return StepMatch(patternText: text, arguments: arguments)
    }
}

/// The set of registered step patterns. Matching a step finds exactly one pattern,
/// or fails with a typed error — a step matched by zero patterns is undefined, one
/// matched by several is ambiguous. This is the step library's dispatch table
/// without the actions; the Mac/Docker harness binds each pattern to its behaviour.
public struct StepRegistry {

    private let patterns: [StepPattern]

    public init(patterns patternTexts: [String]) throws {
        self.patterns = try patternTexts.map(StepPattern.init)
    }

    /// Find the single pattern matching `step` and return its captured arguments.
    /// Throws ``StepMatchError/undefined(_:)`` if none match or
    /// ``StepMatchError/ambiguous(step:patterns:)`` if more than one does.
    public func match(_ step: GherkinStep) throws -> StepMatch {
        let matches = patterns.compactMap { $0.match(step.text) }
        switch matches.count {
        case 0:
            throw StepMatchError.undefined(step.text)
        case 1:
            return matches[0]
        default:
            throw StepMatchError.ambiguous(step: step.text, patterns: matches.map(\.patternText))
        }
    }
}
