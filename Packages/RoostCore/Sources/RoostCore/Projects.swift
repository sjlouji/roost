import Foundation

/// Layout: `<project>/default/<repo>` holds main clones, `<project>/<task>/<repo>` holds worktrees.
public enum Projects {
    public static let mainFolder = "default"
    static let skippedFolders: Set<String> = ["node_modules", "Library", "build", "dist", "target", "vendor"]

    public static func checkoutURL(for project: Project, repoName: String) -> URL {
        Paths.url(project.path).appendingPathComponent(mainFolder).appendingPathComponent(repoName)
    }

    public static func isCloned(_ checkout: URL) -> Bool {
        FileManager.default.fileExists(atPath: checkout.appendingPathComponent(".git").path)
    }

    /// The repo for an address: its name, and the account alias when the address uses one (plain github.com → nil).
    public static func repo(forRemote remote: String, accountAlias: String?) throws -> Repo {
        guard let parsed = GitRemote(remote) else { throw RoostError.invalidRemote(remote) }
        return Repo(name: parsed.name, remote: remote.trimmingCharacters(in: .whitespaces), accountAlias: accountAlias)
    }

    // MARK: - Finding what's already on disk

    /// Folders under `root` that follow the project layout (a `default/` folder of Git clones).
    /// Doesn't descend into repos or into a project once found.
    public static func discover(under root: URL, maxDepth: Int = 3) -> [Project] {
        var found: [Project] = []
        func visit(_ folder: URL, depth: Int) {
            guard depth <= maxDepth, !skippedFolders.contains(folder.lastPathComponent) else { return }
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) { return }
            let main = folder.appendingPathComponent(mainFolder)
            let clones = Paths.subdirectories(of: main).filter(isCloned)
            if !clones.isEmpty {
                found.append(Project(
                    name: folder.lastPathComponent,
                    path: Paths.abbreviate(folder.path),
                    repos: clones.map(discoveredRepo)
                ))
                return
            }
            for child in Paths.subdirectories(of: folder) { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return found
    }

    static func discoveredRepo(at checkout: URL) -> Repo {
        let config = try? INIFile.read(checkout.appendingPathComponent(".git/config"))
        let remote = config?.values(in: #"remote "origin""#)["url"]
        let host = remote.flatMap(GitRemote.init)?.host
        return Repo(name: checkout.lastPathComponent, remote: remote, accountAlias: host == "github.com" ? nil : host)
    }

    /// Projects from disk plus Roost's saved ones; saved repositories not cloned yet are added to the disk list.
    public static func merge(saved: [Project], discovered: [Project]) -> [Project] {
        var merged = discovered
        for project in saved {
            if let index = merged.firstIndex(where: { $0.id == project.id }) {
                let known = Set(merged[index].repos.map(\.name))
                merged[index].repos += project.repos.filter { !known.contains($0.name) }
            } else {
                merged.append(project)
            }
        }
        return merged.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Clones and tasks

    public static func clone(_ repo: Repo, in project: Project, onLine: LineSink? = nil) async throws {
        guard let remoteText = repo.remote, let remote = GitRemote(remoteText) else {
            throw RoostError.invalidRemote(repo.remote ?? repo.name)
        }
        let destination = checkoutURL(for: project, repoName: repo.name)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw RoostError.destinationExists(Paths.abbreviate(destination.path))
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await Shell.runChecked(
            "git",
            ["clone", remote.sshURL(alias: repo.accountAlias ?? "github.com"), destination.path],
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
        let source = checkoutURL(for: project, repoName: repo.name)
        guard isCloned(source) else { throw RoostError.notCloned(repo.name) }
        let destination = Paths.url(project.path).appendingPathComponent(task).appendingPathComponent(repo.name)
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
        Paths.subdirectories(of: Paths.url(project.path)).map(\.lastPathComponent).filter { $0 != mainFolder }
    }
}
