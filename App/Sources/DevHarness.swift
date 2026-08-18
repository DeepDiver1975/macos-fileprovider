#if DEBUG
import SwiftUI
import FileProvider
import OwnCloudCore
import FileProviderSupport

/// Debug-only local-testing harness for the Task 6.0 spike (see `progress.md`).
///
/// The real sign-in flow (Task 5.2) and the live domain registration (Task 5.1)
/// are not built yet, so there is no shipping code path that seeds credentials or
/// calls `NSFileProviderManager.add(_:)`. This harness stands in for both so a
/// developer can mount a live domain in Finder against the local Docker fixture:
///
///   1. **Sign in** writes a Basic credential into the shared Keychain access
///      group — the initial write only a signed, entitled process can perform.
///   2. **Add domain** registers the domain the extension then serves.
///   3. **Remove domain** tears it down so the flow can be repeated.
///
/// It is compiled only in `DEBUG` and defaults to the Classic fixture
/// (`admin`/`admin` at `http://localhost:8080`); Classic is path-addressed and
/// needs no drive-id resolution, so it exercises the extension end-to-end as-is.
enum DevHarnessConfig {
    /// The shared Keychain access group the app and the extension both use; the
    /// team prefix (`$(AppIdentifierPrefix)`) is applied automatically. Matches
    /// the extension's `keychainAccessGroup` and the `keychain-access-groups`
    /// entitlement.
    static let keychainAccessGroup = "com.owncloud.macos.fileprovider.shared"

    /// The local Classic fixture (`make up BACKEND=classic`).
    static let account = AccountDescriptor(
        backend: .classic,
        serverURL: URL(string: "http://localhost:8080")!,
        username: "admin"
    )
    static let password = "admin"

    /// Classic is a single sync root over its files root (no drive id, Task 7.1).
    static let syncRoot = SyncRoot(account: account, driveID: nil)!
}

@MainActor
final class DevHarnessModel: ObservableObject {
    @Published var status: String = "Idle"

    private var store: CredentialStore {
        KeychainCredentialStore(
            account: DevHarnessConfig.account,
            accessGroup: DevHarnessConfig.keychainAccessGroup
        )
    }

    /// Seed the Basic credential into the shared Keychain so the extension's
    /// `authorization(for:)` resolves a header instead of `nil`.
    func signIn() {
        store.save(.basic(username: DevHarnessConfig.account.username, password: DevHarnessConfig.password))
        status = store.load() == nil
            ? "Sign in FAILED — credential did not persist"
            : "Signed in — credential stored for \(DevHarnessConfig.account.displayName)"
    }

    /// Register the domain the extension serves.
    func addDomain() {
        let identifier = DevHarnessConfig.syncRoot.domainIdentifier
        let domain = NSFileProviderDomain(syncRoot: DevHarnessConfig.syncRoot,
                                          displayName: DevHarnessConfig.account.displayName)
        NSLog("[DevHarness] add(domain:) identifier=%@ rawIdentifier=%@ displayName=%@",
              identifier, domain.identifier.rawValue, domain.displayName)
        NSFileProviderManager.add(domain) { [weak self] error in
            Task { @MainActor in
                if let error = error as NSError? {
                    NSLog("[DevHarness] add FAILED domain=%@ code=%ld userInfo=%@",
                          error.domain, error.code, error.userInfo)
                    self?.status = "Add domain FAILED: \(error.domain) code=\(error.code) — \(error.localizedDescription)\nid=\(identifier)"
                } else {
                    self?.status = "Domain added: \(domain.displayName). Look for it in Finder's sidebar."
                }
            }
        }
    }

    /// Remove the domain and keep downloaded data, so the spike can be re-run.
    func removeDomain() {
        let domain = NSFileProviderDomain(syncRoot: DevHarnessConfig.syncRoot,
                                          displayName: DevHarnessConfig.account.displayName)
        // The completion hands back the URL where preserved data was moved (unused
        // here) plus any error.
        NSFileProviderManager.remove(domain, mode: DomainRemovalChoice.default.removalMode) { [weak self] _, error in
            Task { @MainActor in
                self?.status = error.map { "Remove domain FAILED: \($0.localizedDescription)" }
                    ?? "Domain removed."
            }
        }
    }

    /// Clear the stored credential.
    func signOut() {
        store.clear()
        status = "Credential cleared."
    }
}

struct DevHarnessView: View {
    @StateObject private var model = DevHarnessModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Local test harness (DEBUG)")
                .font(.headline)
            Text("Classic fixture · \(DevHarnessConfig.account.displayName)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Sign in", action: model.signIn)
                Button("Add domain", action: model.addDomain)
                Button("Remove domain", action: model.removeDomain)
                Button("Sign out", action: model.signOut)
            }
            Text(model.status)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(minWidth: 420)
    }
}
#endif
