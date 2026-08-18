import Foundation

/// Binds the acceptance catalog's server-side step patterns (Task 6.4) to the
/// ``ClassicBackendAdmin`` action bodies (Task 6.3), producing the
/// ``ScenarioRunner/ActionLookup`` the runner dispatches through. This is the join
/// between three otherwise-disconnected pieces: the catalog says *which* steps exist,
/// the runner walks a scenario's steps, and the admin performs the WebDAV operations —
/// these bindings say *which admin call each server-side step triggers*.
///
/// Only the fixture-state steps (`the server has a file …`, `… a folder … containing
/// N files`, `a file … is created on the server`, `the file … is deleted on the
/// server`) are bound here — the ones a Classic (WebDAV) backend can drive headlessly.
/// The domain-lifecycle and assertion steps (enumerate, materialise, sign out …) stay
/// unbound so the runner reports them as `no action bound` rather than this layer
/// silently swallowing them; they are the Mac-only half wired in the signed harness.
///
/// Pure wiring over an injected ``ClassicBackendAdmin``, so a `ScenarioRunner` built on
/// it runs entirely against a stub transport in tests.
public struct ClassicStepBindings: Sendable {

    private let admin: ClassicBackendAdmin

    public init(admin: ClassicBackendAdmin) {
        self.admin = admin
    }

    /// The `ScenarioRunner.ActionLookup`: resolves a matched pattern's text to the
    /// admin call it drives, or `nil` for the steps this layer does not own.
    public var lookup: ScenarioRunner.ActionLookup {
        let admin = self.admin
        return { patternText in
            switch patternText {
            case "the server has a file {string}",
                 "a file {string} is created on the server":
                return { match in
                    let path = try Self.string(match, at: 0)
                    let contents = Data("provisioned by the acceptance harness\n".utf8)
                    try await admin.createFile(path: path, contents: contents)
                }

            case "the server has a folder {string} containing {int} files":
                return { match in
                    let path = try Self.string(match, at: 0)
                    let count = try Self.int(match, at: 1)
                    try await admin.createFolder(path: path, fileCount: count)
                }

            case "the file {string} is deleted on the server":
                return { match in
                    let path = try Self.string(match, at: 0)
                    try await admin.deleteFile(path: path)
                }

            default:
                return nil
            }
        }
    }

    /// A step whose bound pattern expected an argument the match did not supply — a
    /// wiring bug (catalog pattern and binding disagree), surfaced rather than crashing.
    enum BindingError: Error, Equatable {
        case missingArgument(index: Int, kind: String)
    }

    private static func string(_ match: StepMatch, at index: Int) throws -> String {
        guard index < match.arguments.count, case .string(let value) = match.arguments[index] else {
            throw BindingError.missingArgument(index: index, kind: "string")
        }
        return value
    }

    private static func int(_ match: StepMatch, at index: Int) throws -> Int {
        guard index < match.arguments.count, case .int(let value) = match.arguments[index] else {
            throw BindingError.missingArgument(index: index, kind: "int")
        }
        return value
    }
}
