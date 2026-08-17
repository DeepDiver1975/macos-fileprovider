import Foundation

/// A backend-agnostic classification of a failed remote operation, derived from
/// the HTTP status both WebDAV (ownCloud Classic) and Graph (oCIS) return. The
/// replicated extension maps each case onto the `NSFileProviderError` /
/// `NSError` the system expects (retry, re-authenticate, surface a conflict);
/// that translation is the Mac-only adapter in `FileProviderSupport`.
///
/// Keeping the *decision* here — which status means what — makes it testable
/// without the FileProvider framework and shared by both backends.
public enum RemoteError: Error, Equatable {
    /// 401 — credentials missing, expired, or rejected; trigger re-auth.
    case authenticationRequired
    /// 403 — authenticated but not allowed to perform this operation.
    case insufficientPermissions
    /// 404 — the item (or its parent) no longer exists on the server.
    case noSuchItem
    /// 409 / 412 — the item changed on the server since our base version
    /// (`If-Match` precondition failed, or a create/move collided).
    case versionConflict
    /// 507 — the server is out of storage for this account.
    case insufficientQuota
    /// 5xx and any other status we can't classify — treat as transient.
    case serverError

    /// Classify an HTTP status code. Returns `nil` for the 2xx range, which is
    /// success and therefore not an error.
    public init?(statusCode: Int) {
        switch statusCode {
        case 200...299:
            return nil
        case 401:
            self = .authenticationRequired
        case 403:
            self = .insufficientPermissions
        case 404:
            self = .noSuchItem
        case 409, 412:
            self = .versionConflict
        case 507:
            self = .insufficientQuota
        default:
            // 5xx, and any unclassified non-2xx (e.g. 4xx we don't special-case),
            // are surfaced as a server error rather than silently ignored.
            self = .serverError
        }
    }
}
