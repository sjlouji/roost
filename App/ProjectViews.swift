import AppKit
import RoostCore
import SwiftUI

struct ProjectDetail: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var sheet: Sheet?

    enum Sheet: Identifiable {
        case addRepo, newTask
        var id: Self { self }
    }

    private var clonedRepos: [Repo] {
        project.repos.filter { Projects.isCloned(Projects.checkoutURL(for: project, repoName: $0.name)) }
    }

    var body: some View {
        let _ = model.diskVersion
        Form {
            Section("Folder") {
                LabeledContent("Path") { Text(project.path).textSelection(.enabled) }
                Button("Show in Finder") { model.reveal(Paths.url(project.path)) }
            }
            Section {
                if project.repos.isEmpty {
                    Text("No repositories yet.").foregroundStyle(.secondary)
                }
                ForEach(project.repos) { repo in
                    RepoRow(project: project, repo: repo)
                }
                Button("Add repository…") { sheet = .addRepo }
                    .disabled(model.state.accounts.isEmpty)
            } header: {
                Text("Repositories")
            } footer: {
                if model.state.accounts.isEmpty { Text("Add a GitHub account first, so Roost knows which key to clone with.") }
            }
            Section {
                let tasks = Projects.tasks(in: project)
                if tasks.isEmpty {
                    Text("No tasks yet.").foregroundStyle(.secondary)
                }
                ForEach(tasks, id: \.self) { task in
                    HStack {
                        Label(task, systemImage: "arrow.triangle.branch")
                        Spacer()
                        Button("Show") { model.reveal(Paths.url(project.path).appendingPathComponent(task)) }
                            .buttonStyle(.borderless)
                    }
                }
                Button("New task…") { sheet = .newTask }
                    .disabled(clonedRepos.isEmpty || model.runningTask != nil)
            } header: {
                Text("Tasks")
            } footer: {
                Text("A task is a folder of worktrees, one per repo, each on its own branch: \(project.path)/<task>/<repo>.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(project.name)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .addRepo: AddRepoSheet(project: project)
            case .newTask: NewTaskSheet(project: project, repos: clonedRepos)
            }
        }
    }
}

struct RepoRow: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let repo: Repo

    var body: some View {
        let remote = GitRemote(repo.remote)
        let checkout = Projects.checkoutURL(for: project, repoName: repo.name)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name).font(.headline)
                Text("\(remote.map { "\($0.owner)/\($0.name)" } ?? repo.remote) · \(model.account(repo.accountID)?.label ?? "account removed")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if Projects.isCloned(checkout) {
                Label("Cloned", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Show") { model.reveal(checkout) }.buttonStyle(.borderless)
            } else {
                Button("Clone") { model.clone(repo, in: project) }
                    .disabled(model.runningTask != nil)
            }
        }
        .contextMenu {
            Button("Remove from project") { model.removeRepo(repo, from: project.id) }
        }
    }
}

struct AddProjectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var chosenPath: String?

    private var path: String { chosenPath ?? "~/Documents/\(Slug.make(name))" }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("Acme Platform"))
                LabeledContent("Folder") {
                    HStack {
                        Text(path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Choose…", action: chooseFolder)
                    }
                }
            } footer: {
                Text("Main clones go in \(path)/default/<repo>, task worktrees in \(path)/<task>/<repo>.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") {
                    model.addProject(name: name.trimmingCharacters(in: .whitespaces), path: path)
                    dismiss()
                }
                .disabled(Slug.make(name).isEmpty)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        if panel.runModal() == .OK, let url = panel.url {
            chosenPath = Paths.abbreviate(url.path)
        }
    }
}

struct AddRepoSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project
    @State private var remote = ""
    @State private var accountID: UUID?

    private var parsed: GitRemote? { GitRemote(remote) }
    private var account: GitAccount? { accountID.flatMap(model.account) }

    var body: some View {
        Form {
            Section {
                TextField("Repository", text: $remote, prompt: Text("git@github.com:owner/repo.git or https://github.com/owner/repo"))
                Picker("Clone with", selection: $accountID) {
                    ForEach(model.state.accounts) { account in
                        Text("\(account.label) (\(account.hostAlias))").tag(Optional(account.id))
                    }
                }
            }
            if let parsed, let account {
                Section("Roost will clone") {
                    Text(verbatim: parsed.sshURL(alias: account.hostAlias)).font(.body.monospaced())
                    Text("into \(project.path)/default/\(parsed.name)").foregroundStyle(.secondary)
                }
            } else if !remote.isEmpty {
                Text("That isn't a repository address yet.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .onAppear { accountID = accountID ?? model.state.accounts.first?.id }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    if let accountID { model.addRepo(remote: remote, accountID: accountID, to: project.id) }
                    dismiss()
                }
                .disabled(parsed == nil || account == nil)
            }
        }
    }
}

struct NewTaskSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project
    let repos: [Repo]
    @State private var repoID: UUID?
    @State private var task = ""
    @State private var branch = ""
    @State private var createBranch = true

    private var repo: Repo? { repos.first { $0.id == repoID } }
    private var taskName: String { Slug.make(task) }
    private var branchName: String { branch.isEmpty ? taskName : branch.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        Form {
            Section {
                Picker("Repository", selection: $repoID) {
                    ForEach(repos) { repo in Text(repo.name).tag(Optional(repo.id)) }
                }
                TextField("Task", text: $task, prompt: Text("fs-123-fix-login"))
                TextField("Branch", text: $branch, prompt: Text(taskName.isEmpty ? "same as the task" : taskName))
                Toggle("Create this branch", isOn: $createBranch)
            } footer: {
                Text(createBranch ? "Starts a new branch from the main clone's current commit." : "Checks out a branch that already exists.")
            }
            if let repo, !taskName.isEmpty {
                Section("Roost will create") {
                    Text("\(project.path)/\(taskName)/\(repo.name)").font(.body.monospaced())
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .onAppear { repoID = repoID ?? repos.first?.id }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") {
                    if let repo {
                        model.addTask(named: taskName, repo: repo, in: project, branch: branchName, createBranch: createBranch)
                    }
                    dismiss()
                }
                .disabled(repo == nil || taskName.isEmpty || branchName.isEmpty)
            }
        }
    }
}
