import Cocoa
import FileProviderUI
import OwnCloudCore

// Principal class for the FileProviderUI extension (progress.md Task 7.9).
//
// The extension is a *launcher*, not a settings host: a sandboxed appex must not
// carry a second sign-in implementation — least of all OIDC. On a re-authentication
// error it shows a minimal "Reconnect" sheet whose one button opens the containing
// app at the failing account's sign-in via the AppLaunchURL custom scheme; the app
// (installed in /Applications, Task 5.1) owns the actual credential flow.
final class ActionViewController: FPUIActionExtensionViewController {

    override func prepare(forError error: Error) {
        // The domain whose session expired is carried on the error; its identifier
        // is a SyncRoot domain identifier, whose account is the reconnect target.
        let accountIdentifier = ActionViewController.accountIdentifier(forError: error)
        loadReconnectView(accountIdentifier: accountIdentifier)
    }

    override func prepare(forAction actionIdentifier: String, itemIdentifiers: [NSFileProviderItemIdentifier]) {
        // No custom UI actions in v1 (progress.md Task 5.2 scope note): non-UI
        // actions live in the File Provider extension via NSExtensionFileProviderActions.
        // Complete immediately so Finder does not wait on a sheet we do not present.
        extensionContext.completeRequest()
    }

    // MARK: - Reconnect sheet

    private func loadReconnectView(accountIdentifier: String?) {
        let container = NSView()
        let label = NSTextField(labelWithString: "Your session has expired. Reconnect to keep syncing.")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0

        let reconnect = NSButton(title: "Reconnect…", target: self, action: #selector(reconnectTapped))
        reconnect.keyEquivalent = "\r"
        reconnect.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(label)
        container.addSubview(reconnect)
        container.addSubview(cancel)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            reconnect.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 20),
            reconnect.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            reconnect.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),

            cancel.centerYAnchor.constraint(equalTo: reconnect.centerYAnchor),
            cancel.trailingAnchor.constraint(equalTo: reconnect.leadingAnchor, constant: -12),
        ])

        self.reconnectAccountIdentifier = accountIdentifier
        // No account to resolve → the button can only cancel; keep the sheet honest.
        reconnect.isEnabled = accountIdentifier != nil
        self.view = container
    }

    /// The account the "Reconnect…" button opens the app at. Set from the error.
    private var reconnectAccountIdentifier: String?

    @objc private func reconnectTapped() {
        guard let accountIdentifier = reconnectAccountIdentifier else {
            cancelTapped()
            return
        }
        // Hand off to the containing app, then finish. The app presents sign-in.
        let url = AppLaunchURL.reconnectURL(accountIdentifier: accountIdentifier)
        NSWorkspace.shared.open(url)
        extensionContext.completeRequest()
    }

    @objc private func cancelTapped() {
        extensionContext.cancelRequest(withError:
            NSError(domain: FPUIErrorDomain, code: Int(FPUIExtensionErrorCode.userCancelled.rawValue)))
    }

    /// Extract the account identifier from a re-authentication error. The failing
    /// domain identifier is a ``SyncRoot`` identifier (`"<driveID>|<accountIdentifier>"`);
    /// the account is what the app signs in, so map the domain back to its account.
    private static func accountIdentifier(forError error: Error) -> String? {
        let nsError = error as NSError
        guard let rawDomain = nsError.userInfo[NSFileProviderErrorItemKey] as? String
            ?? nsError.userInfo["NSFileProviderDomainIdentifier"] as? String,
              let syncRoot = SyncRoot(domainIdentifier: rawDomain) else {
            return nil
        }
        return syncRoot.account.accountIdentifier
    }
}
