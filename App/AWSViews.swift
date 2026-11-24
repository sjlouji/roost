import RoostCore
import SwiftUI

struct AWSPage: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: Sheet?
    @State private var profileToRemove: AWSProfile?

    enum Sheet: Identifiable {
        case add
        case refresh(AWSProfile)
        case move(AWSProfile)

        var id: String {
            switch self {
            case .add: "add"
            case .refresh(let profile): "refresh-\(profile.name)"
            case .move(let profile): "move-\(profile.name)"
            }
        }
    }

    private var plainKeyCount: Int { model.awsProfiles.filter { $0.kind == .accessKey }.count }

    var body: some View {
        let _ = model.diskVersion
        Form {
            let missing = AWSTool.all.filter { AWS.toolPath($0.command) == nil }
            if !missing.isEmpty {
                Section {
                    ForEach(missing) { tool in
                        HStack {
                            Label("\(tool.title) isn't installed", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            Spacer()
                            Button("Install") { model.installTool(formula: tool.formula) }.disabled(model.runningTask != nil)
                        }
                    }
                } header: {
                    Text("Tools")
                } footer: {
                    Text("Installed with Homebrew.")
                }
            }
            if plainKeyCount > 0 {
                Section {
                    Label(
                        "\(plainKeyCount) profile(s) keep a permanent key in plain text in ~/.aws/credentials. Use “Move to Keychain” to store it encrypted instead.",
                        systemImage: "lock.open"
                    )
                    .foregroundStyle(.orange)
                }
            }
            Section {
                if model.awsProfiles.isEmpty {
                    Text("No AWS profiles yet.").foregroundStyle(.secondary)
                }
                ForEach(model.awsProfiles) { profile in
                    AWSProfileRow(profile: profile, sheet: $sheet, profileToRemove: $profileToRemove)
                }
                Button("Add profile…") { sheet = .add }
            } header: {
                HStack {
                    Text("Profiles")
                    Spacer()
                    Button("Check all") { model.checkAllAWSProfiles() }
                        .buttonStyle(.borderless)
                        .disabled(model.awsProfiles.isEmpty || model.runningTask != nil)
                }
            } footer: {
                Text("Read from ~/.aws/config and ~/.aws/credentials. Checking a profile asks AWS which account and user it signs in as.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("AWS")
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .add: AddAWSProfileSheet(kind: .vault, name: "")
            case .refresh(let profile): AddAWSProfileSheet(kind: .temporary, name: profile.name, region: profile.region ?? "")
            case .move(let profile): MoveToKeychainSheet(profile: profile)
            }
        }
        .confirmationDialog(
            "Remove the AWS profile \(profileToRemove?.name ?? "")?",
            isPresented: Binding(get: { profileToRemove != nil }, set: { if !$0 { profileToRemove = nil } }),
            presenting: profileToRemove
        ) { profile in
            Button("Remove", role: .destructive) { model.removeProfile(profile) }
        } message: { profile in
            Text(profile.kind == .vault
                 ? "Deletes it from ~/.aws/config and its key from the Keychain. The key stays active in AWS."
                 : "Deletes it from ~/.aws/config and ~/.aws/credentials. Any key stays active in AWS.")
        }
    }
}

struct AWSTool: Identifiable {
    let command: String
    let formula: String
    let title: String
    var id: String { command }

    static let all = [
        AWSTool(command: "aws", formula: "awscli", title: "The AWS CLI"),
        AWSTool(command: "aws-vault", formula: "aws-vault", title: "aws-vault"),
    ]
}

struct AWSProfileRow: View {
    @Environment(AppModel.self) private var model
    let profile: AWSProfile
    @Binding var sheet: AWSPage.Sheet?
    @Binding var profileToRemove: AWSProfile?

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name).font(.headline)
                Text([profile.kind.title, profile.region, profile.endpoint.map { "endpoint \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(profile.kind == .accessKey ? .orange : .secondary)
                identity
            }
            Spacer()
            HStack {
                switch profile.kind {
                case .sso: Button("Sign in") { model.signInSSO(profile) }
                case .temporary: Button("Refresh…") { sheet = .refresh(profile) }
                case .accessKey: Button("Move to Keychain…") { sheet = .move(profile) }
                default: EmptyView()
                }
                Button("Check") { model.whoAmI(profile) }
            }
            .disabled(model.runningTask != nil)
        }
        .contextMenu {
            Button("Remove profile…", role: .destructive) { profileToRemove = profile }
        }
    }

    @ViewBuilder private var identity: some View {
        switch model.awsIdentities[profile.name] {
        case .signedIn(let account, let arn):
            Label("\(account) · \(arn.split(separator: ":").last.map(String.init) ?? arn)", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .textSelection(.enabled)
        case .failed(let reason):
            Label(reason, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        case nil:
            EmptyView()
        }
    }
}

struct AddAWSProfileSheet: View {
    enum Kind: String, CaseIterable, Identifiable {
        case vault = "Permanent key"
        case temporary = "Temporary credentials"
        case sso = "SSO sign-in"
        var id: Self { self }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var kind: Kind
    @State var name: String
    @State var region = "us-east-1"
    @State private var accessKeyID = ""
    @State private var secretAccessKey = ""
    @State private var sessionToken = ""
    @State private var startURL = ""
    @State private var ssoRegion = "us-east-1"
    @State private var accountID = ""
    @State private var roleName = ""

    private var isRefresh: Bool { kind == .temporary && model.awsProfiles.contains { $0.name == name && $0.kind == .temporary } }

    private var isComplete: Bool {
        guard !name.isEmpty, !region.isEmpty else { return false }
        switch kind {
        case .vault: return !accessKeyID.isEmpty && !secretAccessKey.isEmpty
        case .temporary: return !accessKeyID.isEmpty && !secretAccessKey.isEmpty && !sessionToken.isEmpty
        case .sso: return !startURL.isEmpty && !ssoRegion.isEmpty && !accountID.isEmpty && !roleName.isEmpty
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Type", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(isRefresh)
                TextField("Profile name", text: $name, prompt: Text("work"))
                    .disabled(isRefresh)
                TextField("Region", text: $region, prompt: Text("us-east-1"))
            } footer: {
                Text(footer)
            }
            Section(kind == .sso ? "From your SSO portal" : "Credentials") {
                switch kind {
                case .vault:
                    TextField("Access key ID", text: $accessKeyID)
                    SecureField("Secret access key", text: $secretAccessKey)
                case .temporary:
                    TextField("Access key ID", text: $accessKeyID)
                    SecureField("Secret access key", text: $secretAccessKey)
                    SecureField("Session token", text: $sessionToken)
                case .sso:
                    TextField("Portal URL", text: $startURL, prompt: Text("https://your-org.awsapps.com/start"))
                    TextField("SSO region", text: $ssoRegion)
                    TextField("Account ID", text: $accountID)
                    TextField("Role name", text: $roleName)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(isRefresh ? "Refresh" : "Add") {
                    save()
                    dismiss()
                }
                .disabled(!isComplete || model.runningTask != nil)
            }
        }
    }

    private var footer: String {
        switch kind {
        case .vault: "The key is stored encrypted in your Keychain (through aws-vault); tools get one-hour sessions from it."
        case .temporary: "Temporary credentials expire on their own, so they're kept in ~/.aws/credentials. Refresh them here when they do."
        case .sso: "No keys are stored. Sign in through the browser whenever the session ends."
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedRegion = region.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .vault:
            model.addVaultProfile(name: trimmedName, region: trimmedRegion, accessKeyID: accessKeyID, secretAccessKey: secretAccessKey)
        case .temporary:
            model.setTemporaryCredentials(
                name: trimmedName, region: trimmedRegion, accessKeyID: accessKeyID, secretAccessKey: secretAccessKey, sessionToken: sessionToken
            )
        case .sso:
            model.addSSOProfile(
                name: trimmedName, region: trimmedRegion, startURL: startURL, ssoRegion: ssoRegion, accountID: accountID, roleName: roleName
            )
        }
    }
}

struct MoveToKeychainSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let profile: AWSProfile
    @State private var region = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Profile", value: profile.name)
                TextField("Region", text: $region, prompt: Text("us-east-1"))
            } footer: {
                Text("Roost stores the key in your Keychain through aws-vault, checks the profile still signs in without the plain-text file, and only then deletes the plain-text copy. If the check fails, nothing is deleted.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear { region = profile.region ?? "us-east-1" }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Move") {
                    model.moveToVault(profile, region: region.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .disabled(region.isEmpty || model.runningTask != nil)
            }
        }
    }
}
