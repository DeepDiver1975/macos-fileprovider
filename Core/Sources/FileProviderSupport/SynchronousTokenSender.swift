import Foundation
import OwnCloudCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Why a synchronous token request could not produce a body.
public enum SynchronousTokenSenderError: Error, Equatable {
    /// The transport neither completed nor failed within the timeout. Surfaced
    /// rather than waited on forever, because the caller holds the cross-process
    /// refresh lock while it blocks.
    case timedOut
    /// The transport completed with neither an HTTP response nor an error, so there
    /// is no status to classify.
    case invalidResponse
}

/// A blocking transport for the OIDC token endpoint, supplying
/// ``OIDCRefreshHandler/Send`` (issue #17; the refresh half of Task 2.5).
///
/// `SessionManager.RefreshHandler` is synchronous by design: the refresh runs under
/// the exclusive ``RefreshLock``, where a blocking round-trip is precisely what
/// serializes N extension instances sharing one Keychain item. That means the token
/// POST needs a synchronous send, which is what this is — a `URLSession` data task
/// awaited on a semaphore.
///
/// **This method blocks its calling thread.** Never call it from the main actor. In
/// the extension it runs inside `authorization(for:)`, off the main thread, on the
/// operation's own thread.
///
/// The injected seam is completion-handler shaped rather than `async` on purpose:
/// blocking a Swift-concurrency thread while awaiting a `Task` can deadlock by
/// starving the cooperative pool that would deliver the result. `URLSession`'s
/// completion handler runs on its own delegate queue, outside that pool.
public struct SynchronousTokenSender {

    /// Issues `request` and calls `completion` from any thread. Signature-compatible
    /// with `URLSession.dataTask(with:completionHandler:)`.
    public typealias Perform = (
        _ request: URLRequest,
        _ completion: @escaping (Data?, URLResponse?, Error?) -> Void
    ) -> Void

    private let perform: Perform
    private let timeout: TimeInterval

    /// - Parameters:
    ///   - timeout: how long to block before giving up. Kept well under the File
    ///     Provider framework's own operation deadlines, and short enough that a
    ///     wedged transport does not hold the refresh lock against other instances.
    ///   - perform: the transport. Injected so the blocking/classification behaviour
    ///     is testable without a server.
    public init(timeout: TimeInterval = 30, perform: @escaping Perform) {
        self.timeout = timeout
        self.perform = perform
    }

    /// The production transport: a `URLSession` data task.
    public init(session: URLSession = .shared, timeout: TimeInterval = 30) {
        self.init(timeout: timeout) { request, completion in
            session.dataTask(with: request, completionHandler: completion).resume()
        }
    }

    /// Send `request` and block until its body arrives.
    ///
    /// Status classification matches ``RemoteClient``'s (via ``RemoteError``) with
    /// one deliberate addition: the token endpoint answers a revoked or expired
    /// refresh token with `400 invalid_grant` (RFC 6749 §5.2), so 400 is mapped to
    /// ``RemoteError/authenticationRequired`` — the same signal a 401 gives — rather
    /// than to the transient `serverError` it would otherwise fall into. Without
    /// that, a revoked grant would look like a server hiccup worth retrying forever
    /// instead of prompting the user to reconnect.
    public func send(_ request: RemoteRequest) throws -> Data {
        let urlRequest = try URLRequestFactory.urlRequest(from: request, authorization: nil)

        let semaphore = DispatchSemaphore(value: 0)
        // Written on the transport's thread, read on ours; the semaphore is the
        // happens-before edge between the two.
        let result = Result()
        perform(urlRequest) { data, response, error in
            result.set(data: data, response: response as? HTTPURLResponse, error: error)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw SynchronousTokenSenderError.timedOut
        }

        let (data, response, error) = result.value
        if let error { throw error }
        guard let response else { throw SynchronousTokenSenderError.invalidResponse }
        if response.statusCode == 400 {
            throw RemoteError.authenticationRequired
        }
        if let remoteError = RemoteError(statusCode: response.statusCode) {
            throw remoteError
        }
        return data ?? Data()
    }

    /// A lock-guarded box for the completion's three values, so the write on the
    /// transport's thread and the read on the caller's are not a data race.
    private final class Result: @unchecked Sendable {
        private let mutex = NSLock()
        private var data: Data?
        private var response: HTTPURLResponse?
        private var error: Error?

        func set(data: Data?, response: HTTPURLResponse?, error: Error?) {
            mutex.lock()
            defer { mutex.unlock() }
            self.data = data
            self.response = response
            self.error = error
        }

        var value: (Data?, HTTPURLResponse?, Error?) {
            mutex.lock()
            defer { mutex.unlock() }
            return (data, response, error)
        }
    }
}
