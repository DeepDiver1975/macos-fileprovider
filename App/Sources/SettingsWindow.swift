import SwiftUI
import OwnCloudCore
import FileProviderSupport

/// The app's main window (progress.md Task 7.8) — configuration is the app's only
/// job, so this is the primary `WindowGroup` content, not a separate `Settings`
/// scene. A `NavigationSplitView` with an accounts sidebar and Account / Spaces /
/// Advanced tabs.
///
/// The view layer here is deliberately thin: every decision it renders — the Spaces
/// checklist, the Classic note, the deselect prompt wording, the `userEnabled`
/// warning — comes from the headlessly-tested presenters in `OwnCloudCore`
/// (`SpacesTab`, `SpaceRemovalPrompt`, `DomainEnablementStatus`). SwiftUI only
/// arranges them and forwards the chosen `DomainRemovalChoice` back to the service.
struct SettingsWindow: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        NavigationSplitView {
            List(model.accounts, id: \.accountIdentifier, selection: $model.selectedAccountID) { account in
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName)
                    Text(account.backend == .ocis ? "Infinite Scale" : "Classic")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(account.accountIdentifier)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .safeAreaInset(edge: .bottom) {
                Button {
                    model.beginAddAccount()
                } label: {
                    Label("Add Account…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            if let account = model.selectedAccount {
                AccountDetailView(account: account, model: model)
            } else {
                ContentUnavailableView(
                    "No Account Selected",
                    systemImage: "person.crop.circle",
                    description: Text("Add an account or select one to configure its spaces.")
                )
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .task { await model.reload() }
    }
}

/// The three tabs for the selected account.
private struct AccountDetailView: View {
    let account: AccountDescriptor
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView {
            AccountTab(account: account, model: model)
                .tabItem { Text("Account") }
            SpacesTabView(account: account, model: model)
                .tabItem { Text("Spaces") }
            AdvancedTab(account: account, model: model)
                .tabItem { Text("Advanced") }
        }
        .padding()
    }
}

private struct AccountTab: View {
    let account: AccountDescriptor
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            LabeledContent("Server", value: account.serverURL.absoluteString)
            LabeledContent("User", value: account.username)
            LabeledContent("Type", value: account.backend == .ocis ? "ownCloud Infinite Scale" : "ownCloud Classic")

            // Surface the System Settings toggle rather than letting a disabled
            // domain read as our bug (Task 7.8).
            if let status = model.enablementStatus(for: account), status.isBlocked {
                Section {
                    if let message = status.message {
                        Text(message).foregroundStyle(.orange)
                    }
                    if let paneURL = status.settingsPaneURL {
                        Link("Open System Settings", destination: paneURL)
                    }
                }
            }

            Section {
                Button("Sign Out…", role: .destructive) { model.confirmSignOut(account) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct SpacesTabView: View {
    let account: AccountDescriptor
    @ObservedObject var model: SettingsModel

    var body: some View {
        let tab = model.spacesTab(for: account)
        VStack(alignment: .leading, spacing: 8) {
            List(tab.rows, id: \.driveID) { row in
                Toggle(isOn: model.selectionBinding(account: account, row: row)) {
                    Text(row.name)
                }
                .disabled(tab.selectionDisabled)
            }
            if let note = tab.classicNote {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
        .confirmationDialog(
            model.pendingRemoval?.message ?? "",
            isPresented: model.isRemovalPromptPresented,
            titleVisibility: .visible
        ) {
            if let prompt = model.pendingRemoval {
                Button(prompt.keepChoice.label) { model.resolveRemoval(prompt.keepChoice.choice) }
                Button(prompt.removeChoice.label, role: .destructive) {
                    model.resolveRemoval(prompt.removeChoice.choice)
                }
                Button("Cancel", role: .cancel) { model.cancelRemoval() }
            }
        }
    }
}

private struct AdvancedTab: View {
    let account: AccountDescriptor
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Diagnostics") {
                Button("Collect Diagnostics…") { model.collectDiagnostics(account) }
                Text("Gathers logs for this account to share with support.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Reset") {
                Button("Reset Sync…", role: .destructive) { model.resetDomains(account) }
                Text("Removes and re-adds this account's spaces with a clean local state. "
                     + "Downloaded files are re-fetched on demand.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Version", value: OwnCloudCore.version)
            }
        }
        .formStyle(.grouped)
    }
}
