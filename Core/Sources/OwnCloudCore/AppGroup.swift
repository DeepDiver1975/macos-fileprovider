import Foundation

/// The app group the containing app and its extensions share — the single place its
/// identifier is written in code.
///
/// **The identifier must carry the team-id prefix.** On macOS an application group
/// id is `<TEAMID>.group.…`; the bare `group.…` form is accepted everywhere it is
/// *declared* (compiler, codesign, provisioning) and then fails silently at runtime
/// in a way that is very hard to attribute:
///
///   - The app creates `~/Library/Group Containers/group.…` on first write and, as
///     its creator, keeps working — so the app half of a feature looks correct.
///   - An **extension** asks the sandbox for a container it is not entitled to and
///     is denied. `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`
///     yields a path it cannot open, and `UserDefaults(suiteName:)` yields a suite
///     containing **none** of the app's keys — with no error raised on either side.
///
/// That is exactly how the oCIS refresh path came to be silently disabled: with no
/// ``OIDCSessionRecord`` visible, `FileProviderExtension.makeSession` took its
/// refresh-less fallback and every oCIS mount stopped working 300 seconds after
/// sign-in (`token is expired` server-side), while presenting on the Mac as a
/// TLS/trust failure. `AppGroupIdentifierTests` pins the prefix in every file that
/// declares it so the mistake cannot silently return.
public enum AppGroup {

    /// The team id Xcode expands `$(AppIdentifierPrefix)` to when signing. Declared
    /// here because a *runtime* string cannot reference that build variable, and the
    /// two must agree or the container is denied.
    public static let teamID = "4AP2STM4H5"

    /// The group id without the team prefix — the value inside the entitlements'
    /// `$(AppIdentifierPrefix)…` string.
    public static let bareIdentifier = "group.com.owncloud.macos.fileprovider"

    /// The identifier to pass to `UserDefaults(suiteName:)` and
    /// `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`.
    public static let identifier = "\(teamID).\(bareIdentifier)"
}
