import Foundation

public enum ConnectionStatus: Equatable, Sendable {
    case authenticated(user: String)
    case failed(String)
}

public enum GitAccounts {
    // BatchMode: never hang on a prompt. accept-new: a fresh Mac has no known_hosts entry for github.com yet.
    public static let sshOptions = ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=15"]
    public static var gitSSHCommand: String { (["ssh"] + sshOptions).joined(separator: " ") }

    public static func suggestedAlias(for label: String) -> String { "github-\(Slug.make(label))" }

    public static func suggestedKeyPath(for label: String) -> String {
        "~/.ssh/id_ed25519_\(Slug.make(label).replacingOccurrences(of: "-", with: "_"))"
    }

    public static func hasKey(_ account: GitAccount) -> Bool {
        FileManager.default.fileExists(atPath: Paths.expand(account.keyPath))
    }

    /// GitHub host aliases already in `~/.ssh/config` that Roost doesn't know yet.
    public static func importable(from configText: String, existing: [GitAccount]) -> [GitAccount] {
        let known = Set(existing.map { $0.hostAlias.lowercased() })
        return SSHConfig.parse(configText).compactMap { host in
            guard host.hostName?.lowercased() == "github.com",
                  host.alias.lowercased() != "github.com",
                  !known.contains(host.alias.lowercased()),
                  let identityFile = host.identityFile else { return nil }
            return GitAccount(label: label(fromAlias: host.alias), hostAlias: host.alias, keyPath: identityFile, email: "")
        }
    }

    static func label(fromAlias alias: String) -> String {
        var label = alias
        if label.hasSuffix(".com") { label.removeLast(4) }
        if label.hasPrefix("github-") { label.removeFirst(7) }
        return label.isEmpty ? alias : label
    }

    public static func generateKey(for account: GitAccount, onLine: LineSink? = nil) async throws {
        let path = Paths.expand(account.keyPath)
        guard !FileManager.default.fileExists(atPath: path) else { throw RoostError.keyExists(account.keyPath) }
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let comment = account.email.isEmpty ? account.hostAlias : account.email
        try await Shell.runChecked("ssh-keygen", ["-t", "ed25519", "-C", comment, "-f", path, "-N", ""], onLine: onLine)
    }

    public static func publicKey(for account: GitAccount) throws -> String {
        let path = Paths.expand(account.keyPath) + ".pub"
        guard FileManager.default.fileExists(atPath: path) else { throw RoostError.keyMissing(account.keyPath) }
        return try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// GitHub never opens a shell: a working key exits non-zero with "Hi <user>! You've successfully authenticated".
    public static func testConnection(_ account: GitAccount, onLine: LineSink? = nil) async throws -> ConnectionStatus {
        let result = try await Shell.run("ssh", ["-T"] + sshOptions + ["git@\(account.hostAlias)"], onLine: onLine)
        if let user = authenticatedUser(in: result.output) { return .authenticated(user: user) }
        return .failed(result.output.isEmpty ? "ssh exited with status \(result.status)." : result.output)
    }

    static func authenticatedUser(in output: String) -> String? {
        guard let range = output.range(of: #"Hi [^!]+! You've successfully authenticated"#, options: .regularExpression) else {
            return nil
        }
        return String(output[range].dropFirst(3).prefix { $0 != "!" })
    }
}
