import Foundation

/// A GitHub login reached through its own SSH host alias, so several accounts can live on one Mac.
public struct GitAccount: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var label: String
    public var hostAlias: String
    public var keyPath: String
    public var email: String

    public init(id: UUID = UUID(), label: String, hostAlias: String, keyPath: String, email: String) {
        self.id = id
        self.label = label
        self.hostAlias = hostAlias
        self.keyPath = keyPath
        self.email = email
    }
}

public struct Repo: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var remote: String
    public var accountID: UUID

    public init(id: UUID = UUID(), remote: String, accountID: UUID) {
        self.id = id
        self.remote = remote
        self.accountID = accountID
    }

    public var name: String { GitRemote(remote)?.name ?? remote }
}

/// A folder holding `default/<repo>` main clones and `<task>/<repo>` worktrees.
public struct Project: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var repos: [Repo]

    public init(id: UUID = UUID(), name: String, path: String, repos: [Repo] = []) {
        self.id = id
        self.name = name
        self.path = path
        self.repos = repos
    }
}

public struct RoostState: Codable, Sendable, Equatable {
    public var accounts: [GitAccount]
    public var projects: [Project]

    public init(accounts: [GitAccount] = [], projects: [Project] = []) {
        self.accounts = accounts
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
    case accountMissing(String)
    case commandFailed(command: String, status: Int32, output: String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let name):
            "“\(name)” can't be used as a name. Use lowercase letters, numbers and dashes (like fs-123-fix-login), and not “default”."
        case .invalidRemote(let remote):
            "“\(remote)” isn't a repository address. Use one like git@github.com:owner/repo.git or https://github.com/owner/repo."
        case .hostAliasExists(let alias):
            "~/.ssh/config already has a Host called \(alias). Use “Import from ~/.ssh/config” to bring it into Roost, or pick another account name."
        case .keyExists(let path):
            "\(path) already exists. Roost never overwrites a key: pick another account name, or remove the old key yourself."
        case .keyMissing(let path):
            "There's no key at \(path). Generate one from the account page."
        case .destinationExists(let path):
            "\(path) already exists. Move or delete it, then try again."
        case .notCloned(let repo):
            "\(repo) isn't cloned yet. Clone it first, then create the task."
        case .accountMissing(let repo):
            "The GitHub account for \(repo) was removed from Roost. Remove the repository and add it again with an existing account."
        case .commandFailed(let command, let status, let output):
            "`\(command)` failed (exit \(status)).\n" + output.split(separator: "\n").suffix(4).joined(separator: "\n")
        }
    }
}

public enum Paths {
    public static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }
    public static func url(_ path: String) -> URL { URL(fileURLWithPath: expand(path)) }
    public static func abbreviate(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
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
