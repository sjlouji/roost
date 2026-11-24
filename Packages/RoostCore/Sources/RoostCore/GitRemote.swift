import Foundation

/// An `owner/name` repository parsed from any common Git address form.
public struct GitRemote: Equatable, Sendable {
    public let host: String
    public let owner: String
    public let name: String

    /// Accepts `git@host:owner/name.git`, `ssh://git@host/owner/name.git` and `https://host/owner/name`.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var host: String
        var path: String
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           ["https", "http", "ssh", "git"].contains(scheme), let urlHost = url.host {
            host = urlHost
            path = url.path
        } else if let at = trimmed.firstIndex(of: "@"), let colon = trimmed[at...].firstIndex(of: ":") {
            host = String(trimmed[trimmed.index(after: at)..<colon])
            path = String(trimmed[trimmed.index(after: colon)...])
        } else {
            return nil
        }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") { path.removeLast(4) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !host.isEmpty, parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        self.host = host
        owner = parts[0]
        name = parts[1]
    }

    /// The SSH address that routes through an account's host alias, which picks that account's key.
    public func sshURL(alias: String) -> String { "git@\(alias):\(owner)/\(name).git" }
}
