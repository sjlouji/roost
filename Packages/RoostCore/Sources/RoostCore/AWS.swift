import Foundation

public struct AWSProfile: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case vault, sso, temporary, accessKey, role, process, none

        public var title: String {
            switch self {
            case .vault: "Keychain (aws-vault)"
            case .sso: "SSO sign-in"
            case .temporary: "Temporary credentials"
            case .accessKey: "Plain-text access key"
            case .role: "Assumed role"
            case .process: "Credential command"
            case .none: "No credentials"
            }
        }
    }

    public let name: String
    public let region: String?
    public let kind: Kind
    public let endpoint: String?

    public var id: String { name }
}

public enum AWSIdentity: Equatable, Sendable {
    case signedIn(account: String, arn: String)
    case failed(String)
}

public struct AWSFiles: Sendable {
    public let config: URL
    public let credentials: URL

    public init(config: URL, credentials: URL) {
        self.config = config
        self.credentials = credentials
    }

    public static var standard: AWSFiles {
        AWSFiles(config: Paths.url("~/.aws/config"), credentials: Paths.url("~/.aws/credentials"))
    }

    /// Points the AWS CLI at these files, so a command reads exactly what Roost shows.
    var environment: [String: String] {
        ["AWS_CONFIG_FILE": config.path, "AWS_SHARED_CREDENTIALS_FILE": credentials.path]
    }
}

public enum AWS {
    /// aws-vault keeps keys in the login keychain, which is unlocked while you're logged in.
    public static let vaultBackend = ["--backend=keychain", "--keychain=login"]

    static func configSection(_ name: String) -> String { name == "default" ? "default" : "profile \(name)" }

    // MARK: - Reading

    public static func profiles(in files: AWSFiles = .standard) throws -> [AWSProfile] {
        profiles(config: try INIFile.read(files.config), credentials: try INIFile.read(files.credentials))
    }

    public static func profiles(config: INIFile, credentials: INIFile) -> [AWSProfile] {
        var names: [String] = []
        for section in config.sectionNames {
            if section == "default" {
                names.append(section)
            } else if section.hasPrefix("profile ") {
                names.append(section.dropFirst("profile ".count).trimmingCharacters(in: .whitespaces))
            }
        }
        for section in credentials.sectionNames where !names.contains(section) { names.append(section) }
        return names.map { name in
            let settings = config.values(in: configSection(name))
            return AWSProfile(
                name: name,
                region: settings["region"],
                kind: kind(config: settings, credentials: credentials.values(in: name)),
                endpoint: settings["endpoint_url"]
            )
        }
    }

    static func kind(config: [String: String], credentials: [String: String]) -> AWSProfile.Kind {
        if let process = config["credential_process"] { return process.contains("aws-vault") ? .vault : .process }
        if config["sso_start_url"] != nil || config["sso_session"] != nil { return .sso }
        if config["role_arn"] != nil { return .role }
        if credentials["aws_session_token"] != nil { return .temporary }
        if credentials["aws_access_key_id"] != nil { return .accessKey }
        return .none
    }

    public static func toolPath(_ tool: String) -> String? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].map { "\($0)/\(tool)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func whoAmI(_ profile: String, files: AWSFiles = .standard, onLine: LineSink? = nil) async throws -> AWSIdentity {
        try await whoAmI(profile, environment: files.environment, onLine: onLine)
    }

    static func whoAmI(_ profile: String, environment: [String: String], onLine: LineSink?) async throws -> AWSIdentity {
        guard toolPath("aws") != nil else { throw RoostError.toolMissing("The AWS CLI (aws)") }
        let result = try await Shell.run(
            "aws", ["sts", "get-caller-identity", "--profile", profile, "--output", "json"], environment: environment, onLine: onLine
        )
        if result.succeeded, let identity = parseIdentity(result.output) { return identity }
        return .failed(result.output.split(separator: "\n").last.map(String.init) ?? "exit \(result.status)")
    }

    static func parseIdentity(_ output: String) -> AWSIdentity? {
        guard let start = output.firstIndex(of: "{"),
              let json = try? JSONSerialization.jsonObject(with: Data(output[start...].utf8)) as? [String: Any],
              let account = json["Account"] as? String,
              let arn = json["Arn"] as? String else { return nil }
        return .signedIn(account: account, arn: arn)
    }

    // MARK: - Adding

    public static func validateName(_ name: String) throws {
        let allowed = !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
        guard allowed else { throw RoostError.invalidName(name) }
    }

    static func requireNew(_ name: String, in files: AWSFiles) throws {
        try validateName(name)
        if try profiles(in: files).contains(where: { $0.name == name }) { throw RoostError.profileExists(name) }
    }

    /// Stores a permanent key in the keychain through aws-vault; `aws --profile <name>` then gets one-hour sessions from it.
    public static func addVaultProfile(
        name: String, region: String, accessKeyID: String, secretAccessKey: String,
        files: AWSFiles = .standard, onLine: LineSink? = nil
    ) async throws {
        try requireNew(name, in: files)
        guard let vault = toolPath("aws-vault") else { throw RoostError.toolMissing("aws-vault") }
        try await storeInVault(name, accessKeyID: accessKeyID, secretAccessKey: secretAccessKey, vault: vault, onLine: onLine)
        var config = try INIFile.read(files.config)
        useVault(&config, profile: name, region: region, vault: vault)
        try Paths.writePrivate(config.text, to: files.config)
    }

    /// Temporary credentials expire on their own, so they live in `~/.aws/credentials`. Also refreshes expired ones.
    public static func setTemporaryCredentials(
        name: String, region: String, accessKeyID: String, secretAccessKey: String, sessionToken: String,
        files: AWSFiles = .standard
    ) throws {
        try validateName(name)
        if let existing = try profiles(in: files).first(where: { $0.name == name }), ![.temporary, .none].contains(existing.kind) {
            throw RoostError.profileExists(name)
        }
        var credentials = try INIFile.read(files.credentials)
        credentials.set("aws_access_key_id", accessKeyID, in: name)
        credentials.set("aws_secret_access_key", secretAccessKey, in: name)
        credentials.set("aws_session_token", sessionToken, in: name)
        try Paths.writePrivate(credentials.text, to: files.credentials)
        if !region.isEmpty {
            var config = try INIFile.read(files.config)
            config.set("region", region, in: configSection(name))
            try Paths.writePrivate(config.text, to: files.config)
        }
    }

    /// No keys stored: `aws sso login --profile <name>` signs in through the browser.
    public static func addSSOProfile(
        name: String, region: String, startURL: String, ssoRegion: String, accountID: String, roleName: String,
        files: AWSFiles = .standard
    ) throws {
        try requireNew(name, in: files)
        var config = try INIFile.read(files.config)
        let section = configSection(name)
        config.set("sso_start_url", startURL, in: section)
        config.set("sso_region", ssoRegion, in: section)
        config.set("sso_account_id", accountID, in: section)
        config.set("sso_role_name", roleName, in: section)
        config.set("region", region, in: section)
        try Paths.writePrivate(config.text, to: files.config)
    }

    public static func signInSSO(_ name: String, files: AWSFiles = .standard, onLine: LineSink? = nil) async throws {
        guard toolPath("aws") != nil else { throw RoostError.toolMissing("The AWS CLI (aws)") }
        try await Shell.runChecked("aws", ["sso", "login", "--profile", name], environment: files.environment, onLine: onLine)
    }

    // MARK: - Moving a plain-text key into the keychain

    /// Stores the profile's key in aws-vault, proves it works without the plain file, then deletes the plain copy.
    /// If the check fails, the profile is put back on its plain key.
    public static func moveToVault(_ name: String, region: String, files: AWSFiles = .standard, onLine: LineSink? = nil) async throws {
        guard let vault = toolPath("aws-vault") else { throw RoostError.toolMissing("aws-vault") }
        var credentials = try INIFile.read(files.credentials)
        let values = credentials.values(in: name)
        guard let keyID = values["aws_access_key_id"], let secret = values["aws_secret_access_key"],
              values["aws_session_token"] == nil else { throw RoostError.noPlainKey(name) }

        try await storeInVault(name, accessKeyID: keyID, secretAccessKey: secret, vault: vault, onLine: onLine)
        var config = try INIFile.read(files.config)
        useVault(&config, profile: name, region: region, vault: vault)
        try Paths.writePrivate(config.text, to: files.config)

        let check = try await whoAmI(
            name, environment: ["AWS_CONFIG_FILE": files.config.path, "AWS_SHARED_CREDENTIALS_FILE": "/dev/null"], onLine: onLine
        )
        guard case .signedIn = check else {
            config.removeKey("credential_process", in: configSection(name))
            try Paths.writePrivate(config.text, to: files.config)
            let reason = if case .failed(let message) = check { message } else { "" }
            throw RoostError.commandFailed(command: "aws sts get-caller-identity --profile \(name)", status: 1, output: reason)
        }
        credentials.removeSection(name)
        try Paths.writePrivate(credentials.text, to: files.credentials)
    }

    // MARK: - Removing

    public static func removeProfile(_ profile: AWSProfile, files: AWSFiles = .standard, onLine: LineSink? = nil) async throws {
        if profile.kind == .vault, let vault = toolPath("aws-vault") {
            // Not checked: the keychain entry may already be gone, which is the state we want.
            try await Shell.run(vault, vaultBackend + ["remove", profile.name, "--force"], onLine: onLine)
            try await Shell.run(vault, vaultBackend + ["clear", profile.name], onLine: onLine)
        }
        var config = try INIFile.read(files.config)
        if config.removeSection(configSection(profile.name)) { try Paths.writePrivate(config.text, to: files.config) }
        var credentials = try INIFile.read(files.credentials)
        if credentials.removeSection(profile.name) { try Paths.writePrivate(credentials.text, to: files.credentials) }
    }

    // MARK: - Tools

    public static func install(formula: String, onLine: LineSink? = nil) async throws {
        guard toolPath("brew") != nil else { throw RoostError.toolMissing("Homebrew (brew.sh)") }
        try await Shell.runChecked("brew", ["install", formula], onLine: onLine)
    }

    // MARK: - Helpers

    /// Keys go to aws-vault through its environment, never as arguments, so they don't appear in the log or `ps`.
    static func storeInVault(
        _ name: String, accessKeyID: String, secretAccessKey: String, vault: String, onLine: LineSink?
    ) async throws {
        try await Shell.runChecked(
            vault, vaultBackend + ["add", name, "--env"],
            environment: ["AWS_ACCESS_KEY_ID": accessKeyID, "AWS_SECRET_ACCESS_KEY": secretAccessKey],
            onLine: onLine
        )
    }

    static func useVault(_ config: inout INIFile, profile: String, region: String, vault: String) {
        let section = configSection(profile)
        // aws-vault can't start a session without a region.
        config.set("region", region, in: section)
        config.set("credential_process", ([vault] + vaultBackend + ["exec", profile, "--json"]).joined(separator: " "), in: section)
    }
}
