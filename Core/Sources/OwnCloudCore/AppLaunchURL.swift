import Foundation

/// The custom-scheme link the sandboxed UI extension uses to hand a failing account
/// back to the containing app (Task 7.9). The appex never re-implements sign-in —
/// least of all OIDC; it builds a `reconnect` URL and opens it, and the app resolves
/// the account and presents the right sign-in. Keeping the URL grammar here means
/// both sides agree on one tested contract instead of two hand-rolled string parses.
public enum AppLaunchURL: Equatable {
    /// Open the app at the sign-in for the account whose session failed.
    case reconnect(accountIdentifier: String)

    /// The app's registered URL scheme (`CFBundleURLTypes` in the app Info.plist).
    public static let scheme = "owncloud-fileprovider"

    private static let reconnectHost = "reconnect"
    private static let accountQueryItem = "account"

    /// Build the `reconnect` deep link. The account identifier carries `|` and `%`
    /// (it is `backend|encodedURL|encodedUsername`), so it goes through a query item,
    /// which percent-encodes it rather than letting it collide with URL structure.
    public static func reconnectURL(accountIdentifier: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = reconnectHost
        components.queryItems = [URLQueryItem(name: accountQueryItem, value: accountIdentifier)]
        // The grammar is fixed and valid, so this force-unwrap can only fail on a
        // programming error, not on user input.
        return components.url!
    }

    /// Parse a URL the app was opened with. Returns `nil` for a foreign scheme, an
    /// unknown action, or a `reconnect` link missing its account — the app ignores
    /// anything it does not recognise rather than acting on a malformed link.
    public static func parse(_ url: URL) -> AppLaunchURL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == scheme else { return nil }
        switch components.host {
        case reconnectHost:
            guard let account = components.queryItems?
                .first(where: { $0.name == accountQueryItem })?.value,
                  !account.isEmpty else { return nil }
            return .reconnect(accountIdentifier: account)
        default:
            return nil
        }
    }
}
