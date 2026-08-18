import Foundation

/// The catalog of acceptance step definitions (Task 6.4) — every step pattern the
/// committed `.feature` files use, in one place.
///
/// This is the pattern half of the step library: it maps a step's wording to a
/// definition. The *behaviour* each definition triggers (provision a fixture via
/// `BackendAdmin`, add a domain via `NSFileProviderManager`, assert materialisation)
/// is the Mac/Docker-gated half wired in the test target on the Mac — but the
/// mapping itself is pure, so `AcceptanceStepCatalogTests` can prove headlessly that
/// no scenario references an undefined or ambiguous step.
///
/// Patterns are deliberately specific enough to stay mutually exclusive: e.g.
/// "is listed" / "is not listed" / "is not materialised" are distinct literals, so a
/// single step never matches two definitions.
public enum AcceptanceStepCatalog {

    /// Every step pattern used across the feature files, grouped by the wording they
    /// come from. `{string}` captures a quoted token, `{int}` a number.
    public static let patterns: [String] = [
        // --- Background / sign-in ---
        "a signed-in domain",
        "a signed-in account",
        "the account has a selected space",
        "the account has an unselected space {string}",
        "the account has two selected spaces",
        "the account has two selected spaces sharing one refresh token",
        "the space {string} is selected",

        // --- Server-side fixture state ---
        "the server has a file {string}",
        "the server has a folder {string} containing {int} files",
        "the domain has been enumerated",
        "the file {string} has been downloaded",

        // --- Actions (When) ---
        "the domain is enumerated",
        "the domain observes changes",
        "the domain enumerates the folder {string}",
        "a file {string} is created on the server",
        "the file {string} is deleted on the server",
        "the account signs out",
        "the app reconciles the domain list",
        "the space {string} is deselected keeping downloaded files",
        "the space {string} is deselected removing downloaded files",
        "the space {string} is deselected",
        "both domains refresh the token concurrently",
        "the access token is forced to expire",

        // --- Assertions (Then) ---
        "the item {string} is listed",
        "the item {string} is not listed",
        "the item {string} is not materialised",
        "{int} items are listed",
        "a domain for {string} exists",
        "the domain for {string} no longer exists",
        "the domain for {string} enumerates its files",
        "both domains are removed",
        "both spaces stay authenticated",
        "only one token refresh reaches the server",
        "the account registry is wiped",
        "the account's credential is deleted",
        "the file {string} is gone from disk",
        "the file {string} remains on disk as a local copy",
        "the orphan domain is not removed without confirmation",
        "the space's domain is reported as an orphan",
    ]

    /// Compile the catalog into a ``StepRegistry``. Throws if any pattern is an
    /// invalid Cucumber expression (guarded by a test).
    public static func registry() throws -> StepRegistry {
        try StepRegistry(patterns: patterns)
    }
}
