import Foundation
import Testing
@testable import RoostCore

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("roost-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct GitRemoteTests {
    @Test(arguments: [
        "git@github.com:acme/widget.git",
        "git@github-work:acme/widget",
        "ssh://git@github.com/acme/widget.git",
        "https://github.com/acme/widget",
        "https://github.com/acme/widget.git/",
    ])
    func parsesCommonForms(_ text: String) throws {
        let remote = try #require(GitRemote(text))
        #expect(remote.owner == "acme")
        #expect(remote.name == "widget")
    }

    @Test(arguments: ["", "widget", "https://github.com/acme", "git@github.com:acme/widget/extra"])
    func rejectsNonRepositoryAddresses(_ text: String) {
        #expect(GitRemote(text) == nil)
    }

    @Test func routesThroughAccountAlias() throws {
        let remote = try #require(GitRemote("https://github.com/acme/widget"))
        #expect(remote.sshURL(alias: "github-work") == "git@github-work:acme/widget.git")
    }
}

@Suite struct SlugTests {
    @Test func makesKebabCase() {
        #expect(Slug.make("Work Account") == "work-account")
        #expect(Slug.make("  FS-123: Fix login!! ") == "fs-123-fix-login")
        #expect(Slug.make("***") == "")
    }
}

@Suite struct SSHConfigTests {
    static let sample = """
    Host *
      AddKeysToAgent yes

    Host github-work   # work account
      HostName github.com
      User git
      IdentityFile ~/.ssh/id_ed25519_work

    Host bastion
      HostName 10.0.0.1
      IdentityFile ~/.ssh/bastion.pem

    Host github-personal.com
      HostName=GitHub.com
      IdentityFile ~/.ssh/id_ed25519_personal
    """

    @Test func parsesSingleNameHostsOnly() {
        let hosts = SSHConfig.parse(Self.sample)
        #expect(hosts.map(\.alias) == ["github-work", "bastion", "github-personal.com"])
        #expect(hosts[0].identityFile == "~/.ssh/id_ed25519_work")
        #expect(hosts[2].hostName == "GitHub.com")
    }

    @Test func importsOnlyUnknownGitHubAliases() {
        let known = [GitAccount(label: "work", hostAlias: "github-work", keyPath: "~/.ssh/id_ed25519_work", email: "")]
        let imported = GitAccounts.importable(from: Self.sample, existing: known)
        #expect(imported.map(\.hostAlias) == ["github-personal.com"])
        #expect(imported.first?.label == "personal")
    }

    @Test func addsHostWithBackupAndRefusesDuplicates() throws {
        let directory = try makeTempDirectory()
        let config = directory.appendingPathComponent("config")
        try "Host old\n  HostName example.com".write(to: config, atomically: true, encoding: .utf8)

        try SSHConfig.addHost(alias: "github-work", identityFile: "~/.ssh/id_ed25519_work", at: config)

        let text = try String(contentsOf: config, encoding: .utf8)
        #expect(text.hasPrefix("Host old\n  HostName example.com\n\n# Added by Roost\nHost github-work\n"))
        #expect(text.contains("IdentitiesOnly yes"))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.roost-backup").path))
        let permissions = try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #expect(throws: RoostError.hostAliasExists("GITHUB-WORK")) {
            try SSHConfig.addHost(alias: "GITHUB-WORK", identityFile: "~/.ssh/other", at: config)
        }
    }

    @Test func createsMissingConfig() throws {
        let config = try makeTempDirectory().appendingPathComponent("ssh/config")
        try SSHConfig.addHost(alias: "github-work", identityFile: "~/.ssh/k", at: config)
        #expect(SSHConfig.parse(try String(contentsOf: config, encoding: .utf8)).map(\.alias) == ["github-work"])
    }
}

@Suite struct GitAccountsTests {
    @Test func suggestsAliasAndKeyFromLabel() {
        #expect(GitAccounts.suggestedAlias(for: "Work Account") == "github-work-account")
        #expect(GitAccounts.suggestedKeyPath(for: "Work Account") == "~/.ssh/id_ed25519_work_account")
    }

    @Test func readsAuthenticatedUser() {
        let output = "Hi octo-cat! You've successfully authenticated, but GitHub does not provide shell access."
        #expect(GitAccounts.authenticatedUser(in: output) == "octo-cat")
        #expect(GitAccounts.authenticatedUser(in: "git@github.com: Permission denied (publickey).") == nil)
    }

    @Test func generatesKeyOnceAndNeverOverwrites() async throws {
        let keyPath = try makeTempDirectory().appendingPathComponent("id_ed25519_test").path
        let account = GitAccount(label: "test", hostAlias: "github-test", keyPath: keyPath, email: "test@example.com")

        try await GitAccounts.generateKey(for: account)

        #expect(GitAccounts.hasKey(account))
        #expect(try GitAccounts.publicKey(for: account).hasPrefix("ssh-ed25519 "))
        await #expect(throws: RoostError.keyExists(keyPath)) { try await GitAccounts.generateKey(for: account) }
    }
}

@Suite struct ShellTests {
    @Test func echoesCommandAndCapturesOutput() async throws {
        let lines = LineRecorder()
        let result = try await Shell.run("printf", ["one\\ntwo\\n"], onLine: { await lines.append($0) })
        #expect(result.succeeded)
        #expect(result.output == "one\ntwo")
        #expect(await lines.all.first == "$ printf 'one\\ntwo\\n'")
    }

    @Test func checkedRunThrowsOnFailure() async {
        await #expect(throws: RoostError.self) { try await Shell.runChecked("false", []) }
    }
}

@Suite struct ProjectsTests {
    @Test func createsTaskWorktreeFromMainClone() async throws {
        let root = try makeTempDirectory()
        let project = Project(name: "Demo", path: root.path)
        let repo = Repo(remote: "git@github.com:acme/widget.git", accountID: UUID())
        let main = Projects.checkoutURL(for: project, repoName: "widget")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try await Shell.runChecked("git", ["init", "-q", "-b", "main"], in: main)
        try await Shell.runChecked(
            "git", ["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "init"], in: main
        )

        let worktree = try await Projects.addTask(named: "fs-1-fix", repo: repo, in: project, branch: "fs-1-fix", createBranch: true)

        #expect(worktree.path == root.appendingPathComponent("fs-1-fix/widget").path)
        #expect(FileManager.default.fileExists(atPath: worktree.appendingPathComponent(".git").path))
        #expect(Projects.tasks(in: project) == ["fs-1-fix"])
    }

    @Test func refusesBadTaskNamesAndUnclonedRepos() async throws {
        let project = Project(name: "Demo", path: try makeTempDirectory().path)
        let repo = Repo(remote: "git@github.com:acme/widget.git", accountID: UUID())
        await #expect(throws: RoostError.invalidName("default")) {
            try await Projects.addTask(named: "default", repo: repo, in: project, branch: "x", createBranch: true)
        }
        await #expect(throws: RoostError.invalidName("Fix Login")) {
            try await Projects.addTask(named: "Fix Login", repo: repo, in: project, branch: "x", createBranch: true)
        }
        await #expect(throws: RoostError.notCloned("widget")) {
            try await Projects.addTask(named: "fix", repo: repo, in: project, branch: "x", createBranch: true)
        }
    }
}

@Suite struct StoreTests {
    @Test func roundTripsAndTreatsMissingFileAsEmpty() throws {
        let store = Store(url: try makeTempDirectory().appendingPathComponent("Roost/roost.json"))
        #expect(try store.load() == RoostState())

        let account = GitAccount(label: "work", hostAlias: "github-work", keyPath: "~/.ssh/k", email: "")
        let state = RoostState(
            accounts: [account],
            projects: [Project(name: "Demo", path: "~/Documents/demo", repos: [Repo(remote: "git@github.com:a/b.git", accountID: account.id)])]
        )
        try store.save(state)
        #expect(try store.load() == state)
    }
}

private actor LineRecorder {
    private(set) var all: [String] = []
    func append(_ line: String) { all.append(line) }
}
