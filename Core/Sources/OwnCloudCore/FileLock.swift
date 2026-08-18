import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// A cross-process advisory lock over a file, using `flock` (Task 7.5 / 7.6).
///
/// `flock` locks are held by the *open file description*, so two independent opens
/// of the same path contend — the shape of two processes (or two extension
/// instances) racing. Two uses in this codebase:
///   - the single-instance guard, so two app copies cannot reconcile the domain
///     list concurrently (Task 7.5);
///   - credential-refresh arbitration, so N extension instances do not each rotate
///     the same refresh token and sign each other out (Task 7.6).
///
/// The lock file lives in the app group container in production; the path is
/// injected so tests use a temp file.
public final class FileLock {
    private let path: String
    private var descriptor: Int32 = -1

    public init(path: String) {
        self.path = path
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    /// Try to take the exclusive lock without blocking. Returns `true` if acquired,
    /// `false` if another holder has it. Opens (creating if needed) the lock file
    /// on first use. Throws only if the file cannot be opened at all.
    public func tryLockExclusive() throws -> Bool {
        if descriptor < 0 {
            descriptor = open(path, O_CREAT | O_RDWR, 0o644)
            guard descriptor >= 0 else {
                throw FileLockError.cannotOpen(path: path, errno: errno)
            }
        }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            return true
        }
        // EWOULDBLOCK means another holder has it — an expected outcome, not an error.
        if errno == EWOULDBLOCK {
            return false
        }
        throw FileLockError.lockFailed(errno: errno)
    }

    /// Release the lock. Safe to call when not held.
    public func unlock() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
    }

    /// Run `body` while holding the exclusive lock, blocking until it is available,
    /// and release it afterwards even if `body` throws.
    public func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        if descriptor < 0 {
            descriptor = open(path, O_CREAT | O_RDWR, 0o644)
            guard descriptor >= 0 else {
                throw FileLockError.cannotOpen(path: path, errno: errno)
            }
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw FileLockError.lockFailed(errno: errno)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}

public enum FileLockError: Error, Equatable {
    case cannotOpen(path: String, errno: Int32)
    case lockFailed(errno: Int32)
}
