import Foundation

/// Layout: `<project>/default/<repo>` holds main clones, `<project>/<task>/<repo>` holds worktrees.
public enum Projects {
    public static let mainFolder = "default"

    public static func checkoutURL(for project: Project, repoName: String) -> URL {
        Paths.url(project.path).appendingPathComponent(mainFolder).appendingPathComponent(repoName)
    }

    public static func isCloned(_ checkout: URL) -> Bool {
        FileManager.default.fileExists(atPath: checkout.appendingPathComponent(".git").path)
    }

    public static func clone(_ repo: Repo, in project: Project, using account: GitAccount, onLine: LineSink? = nil) async throws {
        guard let remote = GitRemote(repo.remote) else { throw RoostError.invalidRemote(repo.remote) }
        let destination = checkoutURL(for: project, repoName: remote.name)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw RoostError.destinationExists(Paths.abbreviate(destination.path))
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await Shell.runChecked(
            "git",
            ["clone", remote.sshURL(alias: account.hostAlias), destination.path],
            environment: ["GIT_SSH_COMMAND": GitAccounts.gitSSHCommand],
            onLine: onLine
        )
    }

    public static func validateTaskName(_ name: String) throws {
        guard !name.isEmpty, name != mainFolder, name == Slug.make(name) else { throw RoostError.invalidName(name) }
    }

    /// Creates a worktree of the repo's main clone at `<project>/<task>/<repo>`.
    @discardableResult
    public static func addTask(
        named task: String,
        repo: Repo,
        in project: Project,
        branch: String,
        createBranch: Bool,
        onLine: LineSink? = nil
    ) async throws -> URL {
        try validateTaskName(task)
        guard let remote = GitRemote(repo.remote) else { throw RoostError.invalidRemote(repo.remote) }
        let source = checkoutURL(for: project, repoName: remote.name)
        guard isCloned(source) else { throw RoostError.notCloned(remote.name) }
        let destination = Paths.url(project.path).appendingPathComponent(task).appendingPathComponent(remote.name)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw RoostError.destinationExists(Paths.abbreviate(destination.path))
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var arguments = ["-C", source.path, "worktree", "add"]
        arguments += createBranch ? ["-b", branch, destination.path] : [destination.path, branch]
        try await Shell.runChecked("git", arguments, onLine: onLine)
        return destination
    }

    public static func tasks(in project: Project) -> [String] {
        let root = Paths.url(project.path)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .filter { $0 != mainFolder }
            .sorted()
    }
}
