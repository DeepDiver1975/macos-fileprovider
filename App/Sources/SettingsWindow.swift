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
    @State private var isAddingAccount = false

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
                    model.addAccountError = nil
                    isAddingAccount = true
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
        .sheet(isPresented: $isAddingAccount) {
            AddAccountSheet(model: model, isPresented: $isAddingAccount)
        }
    }
}

/// The Classic "Add Account" sign-in sheet (Task 7.11). A thin field-collector:
/// it gathers the server address, user name and password, then hands them to
/// `SettingsModel.addAccount`, which routes every decision through the tested
/// `SignInResolver`. On success the model publishes no error and the sheet
/// dismisses; on failure the model's `addAccountError` is shown inline.
private struct AddAccountSheet: View {
    @ObservedObject var model: SettingsModel
    @Binding var isPresented: Bool

    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isSigningIn = false

    private var canSubmit: Bool {
        !isSigningIn
            && !server.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add ownCloud Account").font(.headline)

            Form {
                TextField("Server", text: $server, prompt: Text("http://localhost:8080"))
                    .textContentType(.URL)
                    .disableAutocorrection(true)
                TextField("User Name", text: $username)
                    .textContentType(.username)
                SecureField("Password", text: $password)
                    .textContentType(.password)
            }
            .formStyle(.columns)

            if let error = model.addAccountError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { isPresented = false }
                Button("Sign In") { Task { await signIn() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 420)
        .overlay {
            if isSigningIn { ProgressView().controlSize(.large) }
        }
    }

    private func signIn() async {
        isSigningIn = true
        await model.addAccount(serverURL: server, username: username, password: password)
        isSigningIn = false
        // The model clears its error on success; a nil error means we're done.
        if model.addAccountError == nil { isPresented = false }
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
