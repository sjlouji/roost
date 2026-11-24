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

    /// Every GitHub host alias in `~/.ssh/config` that names its own key.
    public static func discover(from configText: String) -> [GitAccount] {
        SSHConfig.parse(configText).compactMap { host in
            guard host.hostName?.lowercased() == "github.com",
                  host.alias.lowercased() != "github.com",
                  let identityFile = host.identityFile else { return nil }
            return GitAccount(hostAlias: host.alias, keyPath: identityFile)
        }
    }

    public static func discover(at url: URL = SSHConfig.defaultURL) throws -> [GitAccount] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return discover(from: try String(contentsOf: url, encoding: .utf8))
    }

    static func label(fromAlias alias: String) -> String {
        var label = alias
        if label.hasSuffix(".com") { label.removeLast(4) }
        if label.hasPrefix("github-") { label.removeFirst(7) }
        return label.isEmpty ? alias : label
    }

    public static func generateKey(for account: GitAccount, comment: String, onLine: LineSink? = nil) async throws {
        let path = Paths.expand(account.keyPath)
        guard !FileManager.default.fileExists(atPath: path) else { throw RoostError.keyExists(account.keyPath) }
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let keyComment = comment.isEmpty ? account.hostAlias : comment
        try await Shell.runChecked("ssh-keygen", ["-t", "ed25519", "-C", keyComment, "-f", path, "-N", ""], onLine: onLine)
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
