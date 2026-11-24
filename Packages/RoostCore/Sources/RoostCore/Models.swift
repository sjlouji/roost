import Foundation

/// A GitHub login reached through its own SSH host alias, so several accounts can live on one Mac.
/// Read live from `~/.ssh/config`; Roost doesn't keep its own copy.
public struct GitAccount: Identifiable, Hashable, Sendable {
    public var hostAlias: String
    public var keyPath: String

    public init(hostAlias: String, keyPath: String) {
        self.hostAlias = hostAlias
        self.keyPath = keyPath
    }

    public var id: String { hostAlias }
    public var label: String { GitAccounts.label(fromAlias: hostAlias) }
}

/// A repository in a project. `remote` is nil for a local repo without an `origin`.
/// `accountAlias` is nil when the remote uses plain `github.com` (the default SSH key).
public struct Repo: Codable, Identifiable, Hashable, Sendable {
    public var name: String
    public var remote: String?
    public var accountAlias: String?

    public init(name: String, remote: String?, accountAlias: String?) {
        self.name = name
        self.remote = remote
        self.accountAlias = accountAlias
    }

    public var id: String { name }
}

/// A folder holding `default/<repo>` main clones and `<task>/<repo>` worktrees.
public struct Project: Codable, Identifiable, Hashable, Sendable {
    public var name: String
    public var path: String
    public var repos: [Repo]

    public init(name: String, path: String, repos: [Repo] = []) {
        self.name = name
        self.path = path
        self.repos = repos
    }

    public var id: String { Paths.expand(path) }
}

/// What Roost saves: projects created in Roost and repositories added but not cloned yet.
/// Everything else is read from disk each time.
public struct RoostState: Codable, Sendable, Equatable {
    public var projects: [Project]

    public init(projects: [Project] = []) {
        self.projects = projects
    }
}

public enum RoostError: LocalizedError, Equatable {
    case invalidName(String)
    case invalidRemote(String)
    case hostAliasExists(String)
    case keyExists(String)
    case keyMissing(String)
    case destinationExists(String)
    case notCloned(String)
    case profileExists(String)
    case noPlainKey(String)
    case toolMissing(String)
    case notABundle(String)
    case commandFailed(command: String, status: Int32, output: String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let name):
            "“\(name)” can't be used as a name. Use letters, numbers and dashes (like fs-123-fix-login), and not “default”."
        case .invalidRemote(let remote):
            "“\(remote)” isn't a repository address. Use one like git@github.com:owner/repo.git or https://github.com/owner/repo."
        case .hostAliasExists(let alias):
            "~/.ssh/config already has a Host called \(alias). Pick another account name."
        case .keyExists(let path):
            "\(path) already exists. Roost never overwrites a key: pick another account name, or remove the old key yourself."
        case .keyMissing(let path):
            "There's no key at \(path). Generate one from the account page."
        case .destinationExists(let path):
            "\(path) already exists. Move or delete it, then try again."
        case .notCloned(let repo):
            "\(repo) isn't cloned yet. Clone it first, then create the task."
        case .profileExists(let name):
            "An AWS profile called \(name) already exists. Pick another name, or remove the old profile first."
        case .noPlainKey(let name):
            "\(name) has no permanent access key in ~/.aws/credentials, so there's nothing to move. Refresh the AWS page."
        case .toolMissing(let tool):
            "\(tool) isn't installed. Install it, then try again."
        case .notABundle(let path):
            "\(path) isn't a Roost Claude export. Pick the folder Roost created with Export."
        case .commandFailed(let command, let status, let output):
            "`\(command)` failed (exit \(status)).\n" + output.split(separator: "\n").suffix(4).joined(separator: "\n")
        }
    }
}

public enum Paths {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    public static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }
    public static func url(_ path: String) -> URL { URL(fileURLWithPath: expand(path)) }
    public static func abbreviate(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func subdirectories(of url: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return entries.filter(isDirectory).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Writes a file only the user can read, creating its folder (also user-only) if needed.
    static func writePrivate(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        // Not atomic: an atomic write would replace a symlinked file (e.g. from a dotfiles repo) with a plain one.
        try text.write(to: url, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public enum Slug {
    /// Lowercase kebab-case from free text: "Work Account" → "work-account".
    public static func make(_ text: String) -> String {
        var slug = ""
        for character in text.lowercased() {
            if character.isASCII && (character.isLetter || character.isNumber) {
                slug.append(character)
            } else if !slug.isEmpty && !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug
    }
}
