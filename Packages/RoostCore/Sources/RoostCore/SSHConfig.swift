import Foundation

public struct SSHHost: Equatable, Sendable {
    public let alias: String
    public let hostName: String?
    public let identityFile: String?
}

public enum SSHConfig {
    public static var defaultURL: URL { Paths.url("~/.ssh/config") }

    /// Single-name `Host` blocks only; wildcard and multi-pattern blocks aren't accounts.
    public static func parse(_ text: String) -> [SSHHost] {
        var hosts: [SSHHost] = []
        var alias: String?
        var hostName: String?
        var identityFile: String?

        func finishBlock() {
            if let alias { hosts.append(SSHHost(alias: alias, hostName: hostName, identityFile: identityFile)) }
            alias = nil
            hostName = nil
            identityFile = nil
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch parts[0].lowercased() {
            case "host":
                finishBlock()
                let isSingleName = !value.contains(" ") && !value.contains("*") && !value.contains("?")
                if isSingleName { alias = value }
            case "match":
                finishBlock()
            case "hostname" where alias != nil:
                hostName = value
            case "identityfile" where alias != nil && identityFile == nil:
                identityFile = value
            default:
                break
            }
        }
        finishBlock()
        return hosts
    }

    public static func block(alias: String, identityFile: String) -> String {
        """
        # Added by Roost
        Host \(alias)
          HostName github.com
          User git
          IdentityFile \(identityFile)
          IdentitiesOnly yes
        """
    }

    /// Appends a GitHub host block. Backs the file up once (`config.roost-backup`) before Roost's first change.
    public static func addHost(alias: String, identityFile: String, at url: URL = defaultURL) throws {
        let fileManager = FileManager.default
        let existing = fileManager.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : ""
        if parse(existing).contains(where: { $0.alias.caseInsensitiveCompare(alias) == .orderedSame }) {
            throw RoostError.hostAliasExists(alias)
        }
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !existing.isEmpty {
            let backup = directory.appendingPathComponent(url.lastPathComponent + ".roost-backup")
            if !fileManager.fileExists(atPath: backup.path) { try fileManager.copyItem(at: url, to: backup) }
        }
        var text = existing
        if !text.isEmpty { text += text.hasSuffix("\n") ? "\n" : "\n\n" }
        text += block(alias: alias, identityFile: identityFile) + "\n"
        // Not atomic: an atomic write would replace a symlinked config (e.g. from a dotfiles repo) with a plain file.
        try text.write(to: url, atomically: false, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
