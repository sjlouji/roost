import RoostCore
import SwiftUI

struct AccountDetail: View {
    @Environment(AppModel.self) private var model
    let account: GitAccount

    var body: some View {
        let _ = model.diskVersion
        Form {
            Section {
                LabeledContent("SSH host alias", value: account.hostAlias)
                LabeledContent("Key file", value: account.keyPath)
            } header: {
                Text("Account")
            } footer: {
                Text("Read from ~/.ssh/config.")
            }
            Section("Clone addresses for this account") {
                Text(verbatim: "git@\(account.hostAlias):<owner>/<repo>.git")
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
            Section("Connect to GitHub") {
                if GitAccounts.hasKey(account) {
                    Button("Copy public key and open GitHub") { model.copyPublicKeyAndOpenGitHub(account) }
                    HStack {
                        Button("Test connection") { model.testConnection(account) }
                            .disabled(model.runningTask != nil)
                        Spacer()
                        connectionStatus
                    }
                } else {
                    Text("No key file at \(account.keyPath).").foregroundStyle(.secondary)
                    Button("Generate key") { model.generateKey(for: account) }
                        .disabled(model.runningTask != nil)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(account.label)
    }

    @ViewBuilder private var connectionStatus: some View {
        switch model.connections[account.hostAlias] {
        case .authenticated(let user):
            Label("Signed in as \(user)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Label("Not connected", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        case nil:
            EmptyView()
        }
    }
}

struct AddAccountSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var email = ""

    private var slug: String { Slug.make(label) }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $label, prompt: Text("Work, Personal…"))
                TextField("Email", text: $email, prompt: Text("Used as the key's comment"))
            } footer: {
                Text("Roost creates a new SSH key and a host alias, so this account's repos always use its own key.")
            }
            if !slug.isEmpty {
                Section("Roost will create") {
                    LabeledContent("Key file", value: GitAccounts.suggestedKeyPath(for: label))
                    LabeledContent("SSH host alias", value: GitAccounts.suggestedAlias(for: label))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") {
                    model.addAccount(label: label.trimmingCharacters(in: .whitespaces), email: email.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .disabled(slug.isEmpty)
            }
        }
    }
}
