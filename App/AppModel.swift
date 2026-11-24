import AppKit
import Observation
import RoostCore

enum SidebarItem: Hashable {
    case aws
    case claude
    case account(String)
    case project(String)
}

/// Everything Roost found on this Mac in one read, made off the main thread.
private struct Snapshot: Sendable {
    let accounts: Result<[GitAccount], any Error>
    let projects: [Project]
    let awsProfiles: Result<[AWSProfile], any Error>
    let claude: Result<ClaudeInventory, any Error>

    static func read(saved: [Project], projectsRoot: URL) -> Snapshot {
        Snapshot(
            accounts: Result { try GitAccounts.discover() },
            projects: Projects.merge(saved: saved, discovered: Projects.discover(under: projectsRoot)),
            awsProfiles: Result { try AWS.profiles() },
            claude: Result { try ClaudeSetup.inventory() }
        )
    }
}

@MainActor
@Observable
final class AppModel {
    var accounts: [GitAccount] = []
    var projects: [Project] = []
    var awsProfiles: [AWSProfile] = []
    var awsIdentities: [String: AWSIdentity] = [:]
    var claude: ClaudeInventory?
    var claudeImportPlan: ClaudeImportPlan?
    var claudeExportReport: ClaudeExportReport?
    var claudeImportReport: ClaudeImportReport?
    var connections: [String: ConnectionStatus] = [:]
    var selection: SidebarItem?
    var log: [String] = []
    var runningTask: String?
    var errorMessage: String?
    var isRefreshing = false
    /// Bumped after anything changes folders on disk, so views re-read clone and task state.
    var diskVersion = 0

    let projectsRoot = "~/Documents"
    private var saved = RoostState()
    private let store = Store()

    init() {
        do {
            saved = try store.load()
        } catch {
            report(error, context: "Couldn't read Roost's saved projects")
        }
        refresh()
    }

    func account(_ alias: String) -> GitAccount? { accounts.first { $0.hostAlias == alias } }
    func project(_ id: String) -> Project? { projects.first { $0.id == id } }

    /// Re-reads ~/.ssh/config, the projects folder, AWS profiles and ~/.claude.
    func refresh() {
        isRefreshing = true
        let savedProjects = saved.projects
        let root = Paths.url(projectsRoot)
        Task {
            let snapshot = await Task.detached { Snapshot.read(saved: savedProjects, projectsRoot: root) }.value
            switch snapshot.accounts {
            case .success(let found): accounts = found
            case .failure(let error): report(error, context: "Couldn't read ~/.ssh/config")
            }
            projects = snapshot.projects
            switch snapshot.awsProfiles {
            case .success(let found): awsProfiles = found
            case .failure(let error): report(error, context: "Couldn't read your AWS profiles")
            }
            switch snapshot.claude {
            case .success(let found): claude = found
            case .failure(let error): report(error, context: "Couldn't read your Claude Code setup")
            }
            diskVersion += 1
            isRefreshing = false
        }
    }

    // MARK: - GitHub accounts

    func addAccount(label: String, email: String) {
        let account = GitAccount(hostAlias: GitAccounts.suggestedAlias(for: label), keyPath: GitAccounts.suggestedKeyPath(for: label))
        perform("Add GitHub account “\(label)”") {
            if GitAccounts.hasKey(account) {
                self.log.append("Using the existing key \(account.keyPath).")
            } else {
                try await GitAccounts.generateKey(for: account, comment: email, onLine: self.sink)
            }
            try SSHConfig.addHost(alias: account.hostAlias, identityFile: account.keyPath)
            self.log.append("Added Host \(account.hostAlias) to ~/.ssh/config.")
            self.selection = .account(account.hostAlias)
            self.refresh()
        }
    }

    func generateKey(for account: GitAccount) {
        perform("Generate key for “\(account.label)”") {
            try await GitAccounts.generateKey(for: account, comment: "", onLine: self.sink)
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
            self.connections[account.hostAlias] = status
            if case .failed = status {
                self.log.append("Not connected yet. Add the public key on GitHub, then test again.")
            }
        }
    }

    // MARK: - Projects

    func addProject(name: String, path: String) {
        do {
            try FileManager.default.createDirectory(at: Paths.url(path), withIntermediateDirectories: true)
            let project = Project(name: name, path: path)
            saved.projects.append(project)
            try store.save(saved)
            log.append("Created project “\(name)” at \(path).")
            selection = .project(project.id)
            refresh()
        } catch {
            report(error, context: "Couldn't create the project")
        }
    }

    func addRepo(remote: String, accountAlias: String?, to project: Project) {
        do {
            let repo = try Projects.repo(forRemote: remote, accountAlias: accountAlias)
            if let index = saved.projects.firstIndex(where: { $0.id == project.id }) {
                saved.projects[index].repos.append(repo)
            } else {
                saved.projects.append(Project(name: project.name, path: project.path, repos: [repo]))
            }
            try store.save(saved)
            refresh()
        } catch {
            report(error, context: "Couldn't add the repository")
        }
    }

    /// Only for repositories Roost is holding before they're cloned; cloned ones live on disk.
    func removePlannedRepo(_ repo: Repo, from project: Project) {
        guard let index = saved.projects.firstIndex(where: { $0.id == project.id }) else { return }
        saved.projects[index].repos.removeAll { $0.name == repo.name }
        do {
            try store.save(saved)
        } catch {
            report(error, context: "Couldn't save after removing the repository")
        }
        refresh()
    }

    func clone(_ repo: Repo, in project: Project) {
        perform("Clone \(repo.name)") {
            try await Projects.clone(repo, in: project, onLine: self.sink)
            self.refresh()
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

    // MARK: - AWS

    func whoAmI(_ profile: AWSProfile) {
        perform("Check AWS profile \(profile.name)") {
            self.awsIdentities[profile.name] = try await AWS.whoAmI(profile.name, onLine: self.sink)
        }
    }

    func checkAllAWSProfiles() {
        let profiles = awsProfiles
        perform("Check every AWS profile") {
            for profile in profiles {
                self.awsIdentities[profile.name] = try await AWS.whoAmI(profile.name, onLine: self.sink)
            }
        }
    }

    func addVaultProfile(name: String, region: String, accessKeyID: String, secretAccessKey: String) {
        perform("Add AWS profile \(name) (Keychain)") {
            try await AWS.addVaultProfile(
                name: name, region: region, accessKeyID: accessKeyID, secretAccessKey: secretAccessKey, onLine: self.sink
            )
            self.awsIdentities[name] = try await AWS.whoAmI(name, onLine: self.sink)
            self.refresh()
        }
    }

    func setTemporaryCredentials(name: String, region: String, accessKeyID: String, secretAccessKey: String, sessionToken: String) {
        perform("Save temporary credentials for \(name)") {
            try AWS.setTemporaryCredentials(
                name: name, region: region, accessKeyID: accessKeyID, secretAccessKey: secretAccessKey, sessionToken: sessionToken
            )
            self.log.append("Saved temporary credentials for \(name) in ~/.aws/credentials.")
            self.awsIdentities[name] = try await AWS.whoAmI(name, onLine: self.sink)
            self.refresh()
        }
    }

    func addSSOProfile(name: String, region: String, startURL: String, ssoRegion: String, accountID: String, roleName: String) {
        do {
            try AWS.addSSOProfile(
                name: name, region: region, startURL: startURL, ssoRegion: ssoRegion, accountID: accountID, roleName: roleName
            )
            log.append("Added SSO profile \(name). Use Sign in to log in through the browser.")
            refresh()
        } catch {
            report(error, context: "Couldn't add the SSO profile")
        }
    }

    func signInSSO(_ profile: AWSProfile) {
        perform("Sign in to \(profile.name)") {
            try await AWS.signInSSO(profile.name, onLine: self.sink)
            self.awsIdentities[profile.name] = try await AWS.whoAmI(profile.name, onLine: self.sink)
        }
    }

    func moveToVault(_ profile: AWSProfile, region: String) {
        perform("Move \(profile.name) into the Keychain") {
            try await AWS.moveToVault(profile.name, region: region, onLine: self.sink)
            self.log.append("\(profile.name) now reads its key from the Keychain; the plain-text copy is deleted.")
            self.awsIdentities[profile.name] = nil
            self.refresh()
        }
    }

    func removeProfile(_ profile: AWSProfile) {
        perform("Remove AWS profile \(profile.name)") {
            try await AWS.removeProfile(profile, onLine: self.sink)
            self.awsIdentities[profile.name] = nil
            self.refresh()
        }
    }

    func installTool(formula: String) {
        perform("Install \(formula)") {
            try await AWS.install(formula: formula, onLine: self.sink)
            self.refresh()
        }
    }

    // MARK: - Claude Code

    func exportClaude(to bundle: URL, options: ClaudeExportOptions) {
        perform("Export Claude Code setup") {
            let report = try await Task.detached { try ClaudeSetup.export(to: bundle, options: options) }.value
            self.log.append("Exported \(report.files) file(s) and \(report.memoryFolders) memory folder(s) to \(Paths.abbreviate(bundle.path)).")
            self.claudeExportReport = report
            self.reveal(bundle)
        }
    }

    func planClaudeImport(from bundle: URL) {
        perform("Read Claude Code export") {
            self.claudeImportPlan = try await Task.detached { try ClaudeSetup.plan(from: bundle) }.value
        }
    }

    func applyClaudeImport(_ plan: ClaudeImportPlan, secrets: [String: String]) {
        claudeImportPlan = nil
        perform("Import Claude Code setup") {
            let report = try await ClaudeSetup.apply(plan, secrets: secrets, onLine: self.sink)
            self.claudeImportReport = report
            self.refresh()
        }
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

    private func report(_ error: Error, context: String) {
        let message = "\(context): \(error.localizedDescription)"
        log.append("✗ " + message)
        errorMessage = message
    }
}
