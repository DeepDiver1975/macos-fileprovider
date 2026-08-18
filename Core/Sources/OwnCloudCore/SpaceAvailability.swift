import Foundation

/// Decides how the extension reacts when a space appears to have vanished
/// server-side (Task 7.7).
///
/// A **root** enumeration returning 404 means the whole space is gone — an admin
/// deleted the drive, or the user's access was revoked. The right response is to
/// **disconnect** the domain (Finder surfaces the reason and stops retrying every
/// operation), **never to remove it**: removal would discard or orphan
/// already-materialised files without the user's consent. Recovery is a
/// `reconnect` when the space returns, and removal stays a deliberate user action
/// in the settings window.
///
/// Every other failure — and a 404 on a *non-root* item, where just that one item
/// is gone — is surfaced as the normal error it already is.
public enum SpaceAvailability {

    /// What the extension should do about an enumeration failure.
    public enum Decision: Equatable {
        /// Disconnect the domain with a human-readable reason Finder displays.
        case disconnect(reason: String)
        /// Hand the error to the system unchanged.
        case surfaceError
    }

    /// The reason string Finder surfaces on disconnect. User-facing, so it names
    /// no status codes.
    public static let spaceUnavailableReason =
        "This space is no longer available on the server. Your downloaded files are kept; "
        + "it will reconnect automatically if the space returns."

    /// The decision for a failure while enumerating the **root** container.
    public static func decide(forRootEnumeration error: RemoteError) -> Decision {
        error == .noSuchItem ? .disconnect(reason: spaceUnavailableReason) : .surfaceError
    }

    /// The decision for a failure while enumerating a container that may or may not
    /// be the root. Only a root 404 is a vanished space; a 404 deeper in the tree
    /// means just that item is gone.
    public static func decide(forEnumeration error: RemoteError, isRootContainer: Bool) -> Decision {
        guard isRootContainer else { return .surfaceError }
        return decide(forRootEnumeration: error)
    }
}
