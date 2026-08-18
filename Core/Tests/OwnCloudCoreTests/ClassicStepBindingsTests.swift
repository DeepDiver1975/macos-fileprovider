import XCTest
@testable import OwnCloudCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Classic server-side step bindings (Task 6.4/6.3 join): the layer that connects
/// the pure `AcceptanceStepCatalog` patterns to the `ClassicBackendAdmin` action
/// bodies, producing the `ScenarioRunner.ActionLookup` the runner consumes. Until this
/// existed, the catalog (patterns), the runner (orchestration), and the admin (bodies)
/// were three disconnected pieces — a scenario's `Given the server has a file …` /
/// `When a file … is created on the server` steps had nowhere to dispatch.
///
/// Binding is pure wiring, so it is proven headlessly: drive a `ScenarioRunner` over
/// the registry + these bindings against a stub transport, and assert the right WebDAV
/// requests reach the wire in order. The same `ClassicBackendAdmin` wired to a live
/// `URLSession` runs it against the Docker fixture (proven separately by
/// `ClassicBackendAdminContractTests`).
final class ClassicStepBindingsTests: XCTestCase {

    private let filesBase = URL(string: "https://cloud.test/remote.php/dav/files/admin")!

    /// Records the URLRequests the transport is asked to perform, in order.
    private final class Transport: @unchecked Sendable {
        private(set) var seen: [URLRequest] = []
        let status: Int
        init(status: Int) { self.status = status }
        func client() -> RemoteClient {
            RemoteClient { [self] req in
                seen.append(req)
                let http = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (Data(), http)
            }
        }
    }

    private func makeRunner(transport: Transport) throws -> ScenarioRunner {
        let admin = ClassicBackendAdmin(filesBaseURL: filesBase, client: transport.client())
        let bindings = ClassicStepBindings(admin: admin)
        let registry = try AcceptanceStepCatalog.registry()
        return ScenarioRunner(registry: registry, lookup: bindings.lookup)
    }

    private func scenario(_ steps: [(StepKeyword, String)]) -> GherkinScenario {
        GherkinScenario(
            name: "test",
            tags: [],
            steps: steps.map { GherkinStep(keyword: $0.0, text: $0.1) })
    }

    /// "the server has a file X" provisions the file via a PUT at its path.
    func testServerHasFileProvisionsIt() async throws {
        let transport = Transport(status: 201)
        let runner = try makeRunner(transport: transport)

        let result = await runner.run(scenario([
            (.given, "the server has a file \"notes.txt\"")
        ]))

        XCTAssertEqual(result.outcome, .passed)
        XCTAssertEqual(transport.seen.count, 1)
        XCTAssertEqual(transport.seen[0].httpMethod, "PUT")
        XCTAssertEqual(transport.seen[0].url, filesBase.appendingPathComponent("notes.txt"))
    }

    /// "the server has a folder X containing N files" MKCOLs then PUTs N files.
    func testServerHasFolderWithNFilesProvisionsAll() async throws {
        let transport = Transport(status: 201)
        let runner = try makeRunner(transport: transport)

        let result = await runner.run(scenario([
            (.given, "the server has a folder \"Big\" containing 3 files")
        ]))

        XCTAssertEqual(result.outcome, .passed)
        XCTAssertEqual(transport.seen.count, 4, "one MKCOL + three PUTs")
        XCTAssertEqual(transport.seen[0].httpMethod, "MKCOL")
        XCTAssertEqual(transport.seen[0].url, filesBase.appendingPathComponent("Big"))
    }

    /// "a file X is created on the server" is a When mapped onto the same createFile.
    func testFileCreatedOnServerProvisionsIt() async throws {
        let transport = Transport(status: 201)
        let runner = try makeRunner(transport: transport)

        let result = await runner.run(scenario([
            (.when, "a file \"new.txt\" is created on the server")
        ]))

        XCTAssertEqual(result.outcome, .passed)
        XCTAssertEqual(transport.seen.count, 1)
        XCTAssertEqual(transport.seen[0].httpMethod, "PUT")
        XCTAssertEqual(transport.seen[0].url, filesBase.appendingPathComponent("new.txt"))
    }

    /// "the file X is deleted on the server" issues a DELETE at its path.
    func testFileDeletedOnServerIssuesDelete() async throws {
        let transport = Transport(status: 204)
        let runner = try makeRunner(transport: transport)

        let result = await runner.run(scenario([
            (.when, "the file \"doomed.txt\" is deleted on the server")
        ]))

        XCTAssertEqual(result.outcome, .passed)
        XCTAssertEqual(transport.seen.count, 1)
        XCTAssertEqual(transport.seen[0].httpMethod, "DELETE")
        XCTAssertEqual(transport.seen[0].url, filesBase.appendingPathComponent("doomed.txt"))
    }

    /// Multiple server-side steps run in order through one runner pass.
    func testMultipleServerStepsRunInOrder() async throws {
        let transport = Transport(status: 201)
        let runner = try makeRunner(transport: transport)

        let result = await runner.run(scenario([
            (.given, "the server has a file \"a.txt\""),
            (.when, "a file \"b.txt\" is created on the server"),
            (.when, "the file \"a.txt\" is deleted on the server"),
        ]))

        XCTAssertEqual(result.outcome, .passed)
        XCTAssertEqual(transport.seen.map(\.httpMethod), ["PUT", "PUT", "DELETE"])
        XCTAssertEqual(transport.seen[0].url, filesBase.appendingPathComponent("a.txt"))
        XCTAssertEqual(transport.seen[1].url, filesBase.appendingPathComponent("b.txt"))
        XCTAssertEqual(transport.seen[2].url, filesBase.appendingPathComponent("a.txt"))
    }

    /// A server error during a bound step surfaces as a failed run, never a silent pass.
    func testServerErrorFailsTheRun() async throws {
        let transport = Transport(status: 500)
        let runner = try makeRunner(transport: transport)

        let result = await runner.run(scenario([
            (.given, "the server has a file \"x.txt\"")
        ]))

        guard case .failed(let step, _) = result.outcome else {
            return XCTFail("expected the 500 to fail the run, got \(result.outcome)")
        }
        XCTAssertEqual(step, "the server has a file \"x.txt\"")
    }

    /// A step the bindings do not cover (a Mac-only domain step) is left unbound so the
    /// runner reports it rather than the bindings silently swallowing it.
    func testUnboundStepIsNotClaimed() async throws {
        let transport = Transport(status: 201)
        let runner = try makeRunner(transport: transport)

        let result = await runner.run(scenario([
            (.when, "the domain is enumerated")
        ]))

        guard case .failed(_, let reason) = result.outcome else {
            return XCTFail("expected the domain step to be unbound, got \(result.outcome)")
        }
        XCTAssertTrue(reason.contains("no action bound"), reason)
        XCTAssertTrue(transport.seen.isEmpty, "an unbound step must not hit the wire")
    }
}
