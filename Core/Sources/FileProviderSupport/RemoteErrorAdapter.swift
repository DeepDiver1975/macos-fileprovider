#if canImport(FileProvider)
import Foundation
import FileProvider
import OwnCloudCore

/// Translates a backend-agnostic ``RemoteError`` into the concrete `Error` the
/// replicated extension's completion handlers must hand the system (progress.md
/// Tasks 4.1–4.4). The classification of *which* status means what is decided in
/// the Linux-buildable core; this is only the mapping onto Apple's error types.
public extension RemoteError {

    /// The system-facing error for this failure. FileProvider-domain codes drive
    /// the system's built-in reactions (re-auth, quota UI, retry); the two cases
    /// with no FileProvider equivalent map to the nearest Cocoa error.
    var asFileProviderError: Error {
        switch self {
        case .authenticationRequired:
            return NSError(domain: NSFileProviderError.errorDomain,
                           code: NSFileProviderError.Code.notAuthenticated.rawValue)
        case .noSuchItem:
            return NSError(domain: NSFileProviderError.errorDomain,
                           code: NSFileProviderError.Code.noSuchItem.rawValue)
        case .insufficientQuota:
            return NSError(domain: NSFileProviderError.errorDomain,
                           code: NSFileProviderError.Code.insufficientQuota.rawValue)
        case .serverError:
            return NSError(domain: NSFileProviderError.errorDomain,
                           code: NSFileProviderError.Code.serverUnreachable.rawValue)
        case .insufficientPermissions:
            // No dedicated FileProvider code; a write-no-permission error is the
            // closest the system understands and it won't blindly retry it.
            return CocoaError(.fileWriteNoPermission)
        case .versionConflict:
            // A diverged server copy (failed If-Match / create collision) surfaces
            // as a non-retryable file-exists conflict.
            return CocoaError(.fileWriteFileExists)
        }
    }
}
#endif
