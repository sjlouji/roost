import Foundation

/// Finds credentials in text before Roost writes anything that might be shared.
/// Documentation-style examples (AWS's published example keys, `user:password@localhost`) aren't reported,
/// so skill reference docs and local dev settings survive an export.
public enum SecretScan {
    static let patterns: [(name: String, regex: String)] = [
        ("AWS access key", #"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#),
        ("private key", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        ("GitHub token", #"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}\b|\bgithub_pat_[A-Za-z0-9_]{40,}\b"#),
        ("Anthropic API key", #"\bsk-ant-[A-Za-z0-9_\-]{20,}"#),
        ("OpenAI-style API key", #"\bsk-[A-Za-z0-9]{32,}\b"#),
        ("Slack token", #"\bxox[abposr]-[A-Za-z0-9-]{10,}"#),
        ("Google API key", #"\bAIza[0-9A-Za-z_\-]{35}\b"#),
        ("bearer token", #"(?i)\bbearer\s+[A-Za-z0-9._\-]{20,}"#),
    ]

    static let urlCredentials = #"[a-zA-Z][a-zA-Z0-9+.-]*://([^/\s:@]+):([^/\s:@]+)@([^/\s:?#'"]+)"#
    /// `AWS_SECRET_ACCESS_KEY="…"`, `export GITHUB_TOKEN=…`, `db_password: …`: a credential-named variable given a value.
    static let secretAssignment = #"(?i)\b([A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|PASSWD|API_?KEY|ACCESS_KEY|PRIVATE_KEY)[A-Z0-9_]*)["']?\s*[=:]\s*["']?([A-Za-z0-9/+_.=-]{20,})"#
    static let placeholderWords = ["example", "your", "xxxx", "placeholder", "changeme", "dummy", "fake", "sample", "redacted"]
    static let placeholderPasswords: Set<String> = [
        "password", "pass", "passwd", "pwd", "secret", "changeme", "change_me", "example", "test", "testing",
        "postgres", "mysql", "root", "admin", "user", "username", "mypassword", "yourpassword", "your_password", "guest",
    ]

    /// Names of the kinds of secret found, e.g. ["GitHub token"].
    public static func findings(in text: String) -> [String] {
        var found = patterns.compactMap { pattern -> String? in
            let real = matches(of: pattern.regex, in: text).filter { !$0[0].contains("EXAMPLE") }
            return real.isEmpty ? nil : pattern.name
        }
        if matches(of: urlCredentials, in: text).contains(where: { !isExampleCredential(password: $0[2], host: $0[3]) }) {
            found.append("password in URL")
        }
        if matches(of: secretAssignment, in: text).contains(where: { looksRandom($0[2]) }) {
            found.append("secret value")
        }
        return found
    }

    /// `user:password@localhost`, `${DB_PASS}@db` and the like are examples or local dev values, not secrets.
    static func isExampleCredential(password: String, host: String) -> Bool {
        let hostName = host.split(separator: ":").first.map { String($0).lowercased() } ?? host.lowercased()
        let localHost = ["localhost", "127.0.0.1", "0.0.0.0", "host.docker.internal"].contains(hostName)
            || !hostName.contains(".")
            || [".local", ".test", ".example", ".internal", "example.com", "example.org"].contains { hostName.hasSuffix($0) }
        let placeholder = placeholderPasswords.contains(password.lowercased())
            || password.hasPrefix("$") || password.hasPrefix("<") || password.hasPrefix("{") || password.hasPrefix("%")
            || password.allSatisfy { $0 == "*" || $0 == "x" || $0 == "X" }
        return localHost || placeholder
    }

    /// Real keys and tokens mix letters and digits; `your-api-key-here` and `${TOKEN}` don't count.
    static func looksRandom(_ value: String) -> Bool {
        let lower = value.lowercased()
        return value.contains(where: \.isNumber) && value.contains(where: \.isLetter)
            && !placeholderWords.contains { lower.contains($0) }
    }

    /// Each match as [whole match, capture 1, capture 2, …].
    static func matches(of pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    /// A variable or header whose name says it carries a credential.
    public static func isSecretName(_ name: String) -> Bool {
        let upper = name.uppercased()
        return ["TOKEN", "SECRET", "PASSWORD", "PASSWD", "API_KEY", "APIKEY", "ACCESS_KEY", "PRIVATE_KEY", "AUTHORIZATION", "CREDENTIAL", "COOKIE"]
            .contains { upper.contains($0) }
    }

    public static func placeholder(_ name: String) -> String { "{{secret:\(name)}}" }

    /// Placeholder names left in text, e.g. `{{secret:GITHUB_TOKEN}}` → "GITHUB_TOKEN".
    public static func placeholders(in text: String) -> [String] {
        let regex = /\{\{secret:([A-Za-z0-9_.\-]+)\}\}/
        return Array(Set(text.matches(of: regex).map { String($0.output.1) })).sorted()
    }
}
