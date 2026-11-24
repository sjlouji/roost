import AppKit
import Observation
import RoostCore

enum SidebarItem: Hashable {
    case account(UUID)
    case project(UUID)
}

@MainActor
@Observable
final class AppModel {
    var state = RoostState()
    var selection: SidebarItem?
    var log: [String] = []
    var runningTask: String?
    var errorMessage: String?
    var connections: [UUID: ConnectionStatus] = [:]
    /// Bumped after anything that changes folders on disk, so views re-read clone and task state.
    var diskVersion = 0

    private let store = Store()

    init() {
        do {
            state = try store.load()
        } catch {
            report(error, context: "Couldn't read Roost's saved accounts and projects")
        }
    }

    func account(_ id: UUID) -> GitAccount? { state.accounts.first { $0.id == id } }
    func project(_ id: UUID) -> Project? { state.projects.first { $0.id == id } }

    // MARK: - Accounts

    func importAccounts() {
        do {
            let url = SSHConfig.defaultURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                log.append("No ~/.ssh/config yet, so there's nothing to import.")
                return
            }
            let found = GitAccounts.importable(from: try String(contentsOf: url, encoding: .utf8), existing: state.accounts)
            guard !found.isEmpty else {
                log.append("No new GitHub accounts found in ~/.ssh/config.")
                return
            }
            state.accounts += found
            try store.save(state)
            log.append("Imported from ~/.ssh/config: " + found.map(\.hostAlias).joined(separator: ", "))
            selection = .account(found[0].id)
        } catch {
            report(error, context: "Couldn't import accounts from ~/.ssh/config")
        }
    }

    func addAccount(label: String, email: String) {
        let account = GitAccount(
            label: label,
            hostAlias: GitAccounts.suggestedAlias(for: label),
            keyPath: GitAccounts.suggestedKeyPath(for: label),
            email: email
        )
        perform("Add GitHub account “\(label)”") {
            if self.state.accounts.contains(where: { $0.hostAlias == account.hostAlias }) {
                throw RoostError.hostAliasExists(account.hostAlias)
            }
            if GitAccounts.hasKey(account) {
                self.log.append("Using the existing key \(account.keyPath).")
            } else {
                try await GitAccounts.generateKey(for: account, onLine: self.sink)
            }
            try SSHConfig.addHost(alias: account.hostAlias, identityFile: account.keyPath)
            self.log.append("Added Host \(account.hostAlias) to ~/.ssh/config.")
            self.state.accounts.append(account)
            try self.store.save(self.state)
            self.selection = .account(account.id)
        }
    }

    func generateKey(for account: GitAccount) {
        perform("Generate key for “\(account.label)”") {
            try await GitAccounts.generateKey(for: account, onLine: self.sink)
            self.diskVersion += 1
        }
    }

    func copyPublicKeyAndOpenGitHub(_ account: GitAccount) {
        do {
            let key = try GitAccounts.publicKey(for: account)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(key, forType: .string)
            if let page = URL(string: "https://github.com/settings/ssh/new") { NSWorkspace.shared.open(page) }
            log.append("Copied the public key for “\(account.label)”. On GitHub, signed in as that account, paste it and save.")
        } catch {
            report(error, context: "Couldn't copy the public key")
        }
    }

    func testConnection(_ account: GitAccount) {
        perform("Test “\(account.label)” on GitHub") {
            let status = try await GitAccounts.testConnection(account, onLine: self.sink)
            self.connections[account.id] = status
            if case .failed = status {
                self.log.append("Not connected yet. Add the public key on GitHub, then test again.")
            }
        }
    }

    func removeAccount(_ account: GitAccount) {
        state.accounts.removeAll { $0.id == account.id }
        connections[account.id] = nil
        selection = nil
        save(context: "Couldn't save after removing the account")
        log.append("Removed “\(account.label)” from Roost. Its key file and ~/.ssh/config entry are untouched.")
    }

    // MARK: - Projects

    func addProject(name: String, path: String) {
        let project = Project(name: name, path: path)
        do {
            try FileManager.default.createDirectory(at: Paths.url(path), withIntermediateDirectories: true)
            state.projects.append(project)
            try store.save(state)
            selection = .project(project.id)
            log.append("Created project “\(name)” at \(path).")
        } catch {
            report(error, context: "Couldn't create the project folder")
        }
    }

    func addRepo(remote: String, accountID: UUID, to projectID: UUID) {
        guard GitRemote(remote) != nil else {
            report(RoostError.invalidRemote(remote), context: "Couldn't add the repository")
            return
        }
        guard let index = state.projects.firstIndex(where: { $0.id == projectID }) else { return }
        state.projects[index].repos.append(Repo(remote: remote.trimmingCharacters(in: .whitespaces), accountID: accountID))
        save(context: "Couldn't save the repository")
    }

    func removeRepo(_ repo: Repo, from projectID: UUID) {
        guard let index = state.projects.firstIndex(where: { $0.id == projectID }) else { return }
        state.projects[index].repos.removeAll { $0.id == repo.id }
        save(context: "Couldn't save after removing the repository")
        log.append("Removed \(repo.name) from the project list. Files on disk are untouched.")
    }

    func clone(_ repo: Repo, in project: Project) {
        guard let account = account(repo.accountID) else {
            report(RoostError.accountMissing(repo.name), context: "Couldn't clone")
            return
        }
        perform("Clone \(repo.name) with “\(account.label)”") {
            try await Projects.clone(repo, in: project, using: account, onLine: self.sink)
            self.diskVersion += 1
        }
    }

    func addTask(named task: String, repo: Repo, in project: Project, branch: String, createBranch: Bool) {
        perform("Create task \(task) for \(repo.name)") {
            let worktree = try await Projects.addTask(
                named: task, repo: repo, in: project, branch: branch, createBranch: createBranch, onLine: self.sink
            )
            self.log.append("Worktree ready at \(Paths.abbreviate(worktree.path)).")
            self.diskVersion += 1
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Running work

    private var sink: LineSink {
        { [weak self] line in await self?.appendLog(line) }
    }

    private func appendLog(_ line: String) {
        log.append(line)
    }

    /// One action at a time, so two commands never race on the same files.
    private func perform(_ title: String, _ work: @escaping @MainActor () async throws -> Void) {
        guard runningTask == nil else { return }
        runningTask = title
        log.append("▶ \(title)")
        Task {
            do {
                try await work()
                log.append("✓ \(title)")
            } catch {
                report(error, context: title)
            }
            runningTask = nil
        }
    }

    private func save(context: String) {
        do {
            try store.save(state)
        } catch {
            report(error, context: context)
        }
    }

    private func report(_ error: Error, context: String) {
        let message = "\(context): \(error.localizedDescription)"
        log.append("✗ " + message)
        errorMessage = message
    }
}
