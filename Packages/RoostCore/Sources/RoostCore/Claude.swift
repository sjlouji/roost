import Foundation

public struct ClaudeSkill: Identifiable, Hashable, Sendable {
    public let name: String
    public let bytes: Int64
    /// Dependency folders (node_modules, .venv…) that export leaves out.
    public let skippedBytes: Int64
    public var id: String { name }
}

public struct ClaudeMarketplace: Codable, Hashable, Sendable {
    public let name: String
    /// `owner/repo` for GitHub, a Git URL, or a local path.
    public let source: String
}

public struct ClaudeMCPServer: Identifiable, Hashable, Sendable {
    public let name: String
    /// nil for a server available in every project.
    public let projectPath: String?
    public var id: String { (projectPath ?? "") + "/" + name }
}

public struct ClaudeMemory: Identifiable, Hashable, Sendable {
    public let folder: String
    /// The project this memory belongs to, or nil when that folder no longer exists.
    public let projectPath: String?
    public let files: Int
    public var id: String { folder }
}

public struct ClaudeInventory: Sendable {
    public var hasClaudeMD = false
    public var hasSettings = false
    public var rules: [String] = []
    public var agents: [String] = []
    public var commands: [String] = []
    public var hooks: [String] = []
    public var skills: [ClaudeSkill] = []
    public var plugins: [String] = []
    public var marketplaces: [ClaudeMarketplace] = []
    public var mcpServers: [ClaudeMCPServer] = []
    public var memory: [ClaudeMemory] = []
}

public struct ClaudeExportOptions: Sendable {
    /// Your own CLAUDE.md and rules. Off when exporting for someone else.
    public var includePersonal: Bool
    public var includeMemory: Bool

    public init(includePersonal: Bool, includeMemory: Bool) {
        self.includePersonal = includePersonal
        self.includeMemory = includeMemory
    }
}

public struct ClaudeExportReport: Identifiable, Sendable {
    public let id = UUID()
    public var files = 0
    public var memoryFolders = 0
    public var skipped: [String] = []
    public var scrubbed: [String] = []
}

public struct ClaudeMCPInstall: Identifiable, Hashable, Sendable {
    public let name: String
    public let projectPath: String?
    public let json: String
    public var id: String { (projectPath ?? "") + "/" + name }
}

public struct ClaudeImportPlan: Identifiable, Sendable {
    public let id = UUID()

    public struct File: Identifiable, Hashable, Sendable {
        public enum Status: Sendable { case new, changed, same }
        public let label: String
        public let source: URL
        public let destination: URL
        public let status: Status
        public var id: String { destination.path }
    }

    public var files: [File] = []
    public var marketplaces: [ClaudeMarketplace] = []
    public var plugins: [String] = []
    public var mcpServers: [ClaudeMCPInstall] = []
    public var secretsNeeded: [String] = []
    public var skipped: [String] = []
}

public struct ClaudeImportReport: Identifiable, Sendable {
    public let id = UUID()
    public var written = 0
    public var backupFolder: URL?
    public var failures: [String] = []
}

/// Moves a Claude Code setup between Macs: instructions, rules, agents, commands, hooks, skills, settings,
/// plugins, MCP servers and memory. Never moves history, sessions, caches or the login.
public enum ClaudeSetup {
    public static let homeToken = "{{HOME}}"
    static let bundleFormat = "roost-claude"
    static let dependencyFolders: Set<String> = ["node_modules", ".venv", "venv", "__pycache__", ".git", ".pytest_cache", ".mypy_cache", ".ruff_cache"]
    /// claude.ai-managed skills, synced by Claude itself.
    static let managedSkillFolders: Set<String> = ["synced"]
    static let copiedFolders = ["agents", "commands", "hooks"]
    static let maxFileBytes = 10 * 1024 * 1024

    // MARK: - Inventory

    public static func inventory(home: URL = Paths.home) throws -> ClaudeInventory {
        let claude = home.appendingPathComponent(".claude")
        var inventory = ClaudeInventory()
        let fileManager = FileManager.default
        inventory.hasClaudeMD = fileManager.fileExists(atPath: claude.appendingPathComponent("CLAUDE.md").path)
        inventory.hasSettings = fileManager.fileExists(atPath: claude.appendingPathComponent("settings.json").path)
        inventory.rules = entries(in: claude.appendingPathComponent("rules"))
        inventory.agents = entries(in: claude.appendingPathComponent("agents"))
        inventory.commands = entries(in: claude.appendingPathComponent("commands"))
        inventory.hooks = entries(in: claude.appendingPathComponent("hooks"))
        inventory.skills = Paths.subdirectories(of: claude.appendingPathComponent("skills"))
            .filter { !managedSkillFolders.contains($0.lastPathComponent) }
            .map { folder in
                let sizes = sizes(of: folder)
                return ClaudeSkill(name: folder.lastPathComponent, bytes: sizes.kept + sizes.skipped, skippedBytes: sizes.skipped)
            }
        let plugins = try pluginList(claude: claude)
        inventory.plugins = plugins.plugins
        inventory.marketplaces = plugins.marketplaces
        let claudeJSON = try readJSON(home.appendingPathComponent(".claude.json"))
        inventory.mcpServers = mcpServers(in: claudeJSON).map { ClaudeMCPServer(name: $0.name, projectPath: $0.projectPath) }
        inventory.memory = Paths.subdirectories(of: claude.appendingPathComponent("projects")).compactMap { folder in
            let memory = folder.appendingPathComponent("memory")
            let files = entries(in: memory).filter { $0.hasSuffix(".md") }.count
            guard files > 0 else { return nil }
            return ClaudeMemory(folder: folder.lastPathComponent, projectPath: resolveProjectFolder(folder.lastPathComponent), files: files)
        }
        return inventory
    }

    // MARK: - Export

    public static func export(to bundle: URL, home: URL = Paths.home, options: ClaudeExportOptions) throws -> ClaudeExportReport {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: bundle.path), !((try? fileManager.contentsOfDirectory(atPath: bundle.path)) ?? []).isEmpty {
            throw RoostError.destinationExists(Paths.abbreviate(bundle.path))
        }
        let claude = home.appendingPathComponent(".claude")
        let out = bundle.appendingPathComponent("claude")
        var report = ClaudeExportReport()

        if options.includePersonal {
            copyFile(claude.appendingPathComponent("CLAUDE.md"), to: out.appendingPathComponent("CLAUDE.md"), label: "CLAUDE.md", home: home, report: &report)
            copyTree(claude.appendingPathComponent("rules"), to: out.appendingPathComponent("rules"), label: "rules", home: home, report: &report)
        }
        for folder in copiedFolders {
            copyTree(claude.appendingPathComponent(folder), to: out.appendingPathComponent(folder), label: folder, home: home, report: &report)
        }
        for skill in Paths.subdirectories(of: claude.appendingPathComponent("skills")) where !managedSkillFolders.contains(skill.lastPathComponent) {
            let label = "skills/\(skill.lastPathComponent)"
            copyTree(skill, to: out.appendingPathComponent(label), label: label, home: home, report: &report)
        }
        try exportSettings(claude.appendingPathComponent("settings.json"), to: out.appendingPathComponent("settings.json"), home: home, report: &report)

        let plugins = try pluginList(claude: claude)
        try writeJSON(["marketplaces": plugins.marketplaces.map { ["name": $0.name, "source": $0.source] }, "plugins": plugins.plugins],
                      to: bundle.appendingPathComponent("plugins.json"))

        try exportMCP(claudeJSON: try readJSON(home.appendingPathComponent(".claude.json")), to: bundle.appendingPathComponent("mcp.json"), home: home, report: &report)

        if options.includeMemory {
            for folder in Paths.subdirectories(of: claude.appendingPathComponent("projects")) {
                let memory = folder.appendingPathComponent("memory")
                guard !relativeFiles(in: memory).filter({ $0.hasSuffix(".md") }).isEmpty else { continue }
                guard let project = resolveProjectFolder(folder.lastPathComponent), let relative = relativeToHome(project, home: home) else {
                    report.skipped.append("memory for \(folder.lastPathComponent) (its project folder no longer exists)")
                    continue
                }
                copyTree(memory, to: bundle.appendingPathComponent("memory").appendingPathComponent(relative), label: "memory: ~/\(relative)", home: home, report: &report)
                report.memoryFolders += 1
            }
        }

        try writeJSON(
            ["format": bundleFormat, "version": 1, "createdAt": ISO8601DateFormatter().string(from: Date()),
             "includesPersonal": options.includePersonal, "includesMemory": options.includeMemory],
            to: bundle.appendingPathComponent("manifest.json")
        )
        return report
    }

    static func exportSettings(_ source: URL, to destination: URL, home: URL, report: inout ClaudeExportReport) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        var settings = try readJSON(source)
        // Approving a command can save it, secrets and all, as an "always allow" rule. Those rules are disposable.
        if var permissions = settings["permissions"] as? [String: Any] {
            var dropped = 0
            for list in ["allow", "deny", "ask"] {
                guard let rules = permissions[list] as? [String] else { continue }
                let kept = rules.filter { SecretScan.findings(in: $0).isEmpty }
                dropped += rules.count - kept.count
                permissions[list] = kept
            }
            if dropped > 0 {
                settings["permissions"] = permissions
                report.scrubbed.append("settings.json: \(dropped) permission rule(s) containing a secret were left out")
            }
        }
        if var env = settings["env"] as? [String: Any] {
            for (key, value) in env {
                guard let text = value as? String, SecretScan.isSecretName(key) || !SecretScan.findings(in: text).isEmpty else { continue }
                env[key] = SecretScan.placeholder(key)
                report.scrubbed.append("settings.json env \(key)")
            }
            settings["env"] = env
        }
        let text = try jsonText(settings).replacingOccurrences(of: home.path, with: homeToken)
        let findings = SecretScan.findings(in: text)
        guard findings.isEmpty else {
            report.skipped.append("settings.json (still contains a \(findings.joined(separator: ", ")))")
            return
        }
        try write(Data(text.utf8), to: destination, permissions: 0o600)
        report.files += 1
    }

    static func exportMCP(claudeJSON: [String: Any], to destination: URL, home: URL, report: inout ClaudeExportReport) throws {
        var user: [String: Any] = [:]
        var projects: [String: [String: Any]] = [:]
        for server in mcpServers(in: claudeJSON) {
            guard let config = scrubServer(server.config, name: server.name, report: &report) else { continue }
            if let path = server.projectPath {
                let key = relativeToHome(path, home: home).map { "\(homeToken)/\($0)" } ?? path
                projects[key, default: [:]][server.name] = config
            } else {
                user[server.name] = config
            }
        }
        let text = try jsonText(["user": user, "projects": projects]).replacingOccurrences(of: home.path, with: homeToken)
        try write(Data(text.utf8), to: destination, permissions: 0o600)
    }

    /// Replaces credential values with placeholders; nil when a secret remains that Roost can't isolate.
    static func scrubServer(_ server: [String: Any], name: String, report: inout ClaudeExportReport) -> [String: Any]? {
        var config = server
        for field in ["env", "headers"] {
            guard var values = config[field] as? [String: Any] else { continue }
            for (key, value) in values {
                guard let text = value as? String, SecretScan.isSecretName(key) || !SecretScan.findings(in: text).isEmpty else { continue }
                values[key] = SecretScan.placeholder("\(name)_\(key)")
                report.scrubbed.append("MCP \(name) \(field) \(key)")
            }
            config[field] = values
        }
        if let text = try? jsonText(config), !SecretScan.findings(in: text).isEmpty {
            report.skipped.append("MCP server \(name) (a secret sits in its command or URL; add it by hand on the new Mac)")
            return nil
        }
        return config
    }

    // MARK: - Import

    public static func plan(from bundle: URL, home: URL = Paths.home) throws -> ClaudeImportPlan {
        let manifest = try readJSON(bundle.appendingPathComponent("manifest.json"))
        guard manifest["format"] as? String == bundleFormat else { throw RoostError.notABundle(Paths.abbreviate(bundle.path)) }
        let claude = home.appendingPathComponent(".claude")
        var plan = ClaudeImportPlan()
        var secrets: Set<String> = []

        func add(_ source: URL, to destination: URL, label: String) {
            guard let data = try? Data(contentsOf: source) else { return }
            if let text = String(data: data, encoding: .utf8) { secrets.formUnion(SecretScan.placeholders(in: text)) }
            let rendered = render(data, home: home, secrets: [:])
            let status: ClaudeImportPlan.File.Status
            if let existing = try? Data(contentsOf: destination) {
                status = matches(existing, template: rendered) ? .same : .changed
            } else {
                status = .new
            }
            plan.files.append(.init(label: label, source: source, destination: destination, status: status))
        }

        let claudeFolder = bundle.appendingPathComponent("claude")
        for relative in relativeFiles(in: claudeFolder) {
            add(claudeFolder.appendingPathComponent(relative), to: claude.appendingPathComponent(relative), label: relative)
        }
        let memoryFolder = bundle.appendingPathComponent("memory")
        for relative in relativeFiles(in: memoryFolder) {
            let relativeFolder = (relative as NSString).deletingLastPathComponent
            let fileName = (relative as NSString).lastPathComponent
            let projectFolder = encodeProjectPath(home.appendingPathComponent(relativeFolder).path)
            let destination = claude.appendingPathComponent("projects/\(projectFolder)/memory/\(fileName)")
            add(memoryFolder.appendingPathComponent(relative), to: destination, label: "memory: ~/\(relative)")
        }

        let wanted = try readJSON(bundle.appendingPathComponent("plugins.json"))
        let installed = try pluginList(claude: claude)
        let knownMarketplaces = Set(installed.marketplaces.map(\.name))
        plan.marketplaces = (wanted["marketplaces"] as? [[String: String]] ?? []).compactMap { entry in
            guard let name = entry["name"], let source = entry["source"], !knownMarketplaces.contains(name) else { return nil }
            return ClaudeMarketplace(name: name, source: source)
        }
        plan.plugins = (wanted["plugins"] as? [String] ?? []).filter { !installed.plugins.contains($0) }

        let mcpText = (try? String(contentsOf: bundle.appendingPathComponent("mcp.json"), encoding: .utf8)) ?? "{}"
        secrets.formUnion(SecretScan.placeholders(in: mcpText))
        let mcp = (try JSONSerialization.jsonObject(with: Data(mcpText.replacingOccurrences(of: homeToken, with: home.path).utf8)) as? [String: Any]) ?? [:]
        let existing = Set(mcpServers(in: try readJSON(home.appendingPathComponent(".claude.json"))).map(\.id))
        for (name, config) in (mcp["user"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) where !existing.contains("/\(name)") {
            plan.mcpServers.append(ClaudeMCPInstall(name: name, projectPath: nil, json: try jsonText(config, pretty: false)))
        }
        for (path, servers) in (mcp["projects"] as? [String: [String: Any]] ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard Paths.isDirectory(URL(fileURLWithPath: path)) else {
                plan.skipped.append("MCP servers for \(Paths.abbreviate(path)) (that folder doesn't exist on this Mac)")
                continue
            }
            for (name, config) in servers.sorted(by: { $0.key < $1.key }) where !existing.contains("\(path)/\(name)") {
                plan.mcpServers.append(ClaudeMCPInstall(name: name, projectPath: path, json: try jsonText(config, pretty: false)))
            }
        }
        plan.secretsNeeded = secrets.sorted()
        return plan
    }

    /// Writes the plan. Changed files are backed up first; plugin and MCP failures are collected, not fatal.
    public static func apply(
        _ plan: ClaudeImportPlan, secrets: [String: String], home: URL = Paths.home, onLine: LineSink? = nil
    ) async throws -> ClaudeImportReport {
        var report = ClaudeImportReport()
        let changed = plan.files.filter { $0.status == .changed }
        if !changed.isEmpty {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = home.appendingPathComponent(".claude/backups/roost-\(stamp)")
            for file in changed {
                let relative = relativeToHome(file.destination.path, home: home) ?? file.destination.lastPathComponent
                let target = backup.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: file.destination, to: target)
            }
            report.backupFolder = backup
            await onLine?("Backed up \(changed.count) file(s) to \(Paths.abbreviate(backup.path))")
        }
        for file in plan.files where file.status != .same {
            let data = render(try Data(contentsOf: file.source), home: home, secrets: secrets)
            let unfilled = SecretScan.placeholders(in: String(decoding: data, as: UTF8.self))
            if !unfilled.isEmpty {
                report.failures.append("\(file.label): \(unfilled.joined(separator: ", ")) not filled in; edit the file to add it")
            }
            let permissions = (try? FileManager.default.attributesOfItem(atPath: file.source.path)[.posixPermissions] as? Int) ?? 0o644
            try write(data, to: file.destination, permissions: permissions)
            report.written += 1
        }
        await onLine?("Wrote \(report.written) file(s) into ~/.claude")

        for marketplace in plan.marketplaces {
            let result = try await Shell.run("claude", ["plugin", "marketplace", "add", marketplace.source], onLine: onLine)
            if !result.succeeded { report.failures.append("marketplace \(marketplace.name)") }
        }
        for plugin in plan.plugins {
            let result = try await Shell.run("claude", ["plugin", "install", plugin], onLine: onLine)
            if !result.succeeded { report.failures.append("plugin \(plugin)") }
        }
        for server in plan.mcpServers {
            let json = fill(server.json, secrets: secrets)
            guard SecretScan.placeholders(in: json).isEmpty else {
                report.failures.append("MCP server \(server.name) (its secret wasn't filled in)")
                continue
            }
            let scope = server.projectPath == nil ? "user" : "local"
            let directory = server.projectPath.map { URL(fileURLWithPath: $0) }
            let result = try await Shell.run(
                "claude", ["mcp", "add-json", server.name, json, "--scope", scope],
                in: directory, redacting: Array(secrets.values), onLine: onLine
            )
            if !result.succeeded { report.failures.append("MCP server \(server.name)") }
        }
        return report
    }

    // MARK: - Memory folders

    /// Claude names a project's folder by replacing every character that isn't a letter or digit with "-".
    public static func encodeProjectPath(_ path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// The encoding loses "/", ".", "_" and spaces, so the path is recovered by matching real folders from "/" down.
    public static func resolveProjectFolder(_ encoded: String) -> String? {
        guard encoded.hasPrefix("-") else { return nil }
        return resolve(URL(fileURLWithPath: "/"), remaining: String(encoded.dropFirst()))?.path
    }

    static func resolve(_ folder: URL, remaining: String) -> URL? {
        if remaining.isEmpty { return folder }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names {
            let child = folder.appendingPathComponent(name)
            guard Paths.isDirectory(child) else { continue }
            let encoded = encodeProjectPath(name)
            if remaining == encoded { return child }
            if remaining.hasPrefix(encoded + "-"), let found = resolve(child, remaining: String(remaining.dropFirst(encoded.count + 1))) {
                return found
            }
        }
        return nil
    }

    // MARK: - Helpers

    static func relativeToHome(_ path: String, home: URL) -> String? {
        let homePath = home.standardizedFileURL.path
        let fullPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard fullPath.hasPrefix(homePath + "/") else { return nil }
        return String(fullPath.dropFirst(homePath.count + 1))
    }

    static func entries(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// Paths relative to `folder`. Relative paths, because the walker may report `/private/var/…` for a `/var/…` folder.
    static func relativeFiles(in folder: URL, skippingDependencies: Bool = false) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: folder.path) else { return [] }
        var files: [String] = []
        while let relative = enumerator.nextObject() as? String {
            let name = (relative as NSString).lastPathComponent
            if skippingDependencies && dependencyFolders.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            if enumerator.fileAttributes?[.type] as? FileAttributeType == .typeRegular && name != ".DS_Store" {
                files.append(relative)
            }
        }
        return files.sorted()
    }

    static func sizes(of folder: URL) -> (kept: Int64, skipped: Int64) {
        var kept: Int64 = 0
        var skipped: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(atPath: folder.path) else { return (0, 0) }
        while let relative = enumerator.nextObject() as? String {
            guard enumerator.fileAttributes?[.type] as? FileAttributeType == .typeRegular else { continue }
            let size = (enumerator.fileAttributes?[.size] as? NSNumber)?.int64Value ?? 0
            let inDependency = relative.split(separator: "/").contains { dependencyFolders.contains(String($0)) }
            if inDependency { skipped += size } else { kept += size }
        }
        return (kept, skipped)
    }

    static func copyTree(_ source: URL, to destination: URL, label: String, home: URL, report: inout ClaudeExportReport) {
        for relative in relativeFiles(in: source, skippingDependencies: true) {
            copyFile(
                source.appendingPathComponent(relative), to: destination.appendingPathComponent(relative),
                label: "\(label)/\(relative)", home: home, report: &report
            )
        }
    }

    /// Text files get the home folder replaced by {{HOME}}; any file that contains a secret is left out.
    static func copyFile(_ source: URL, to destination: URL, label: String, home: URL, report: inout ClaudeExportReport) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: source.path) else { return }
        guard (attributes[.size] as? Int ?? 0) <= maxFileBytes else {
            report.skipped.append("\(label) (larger than 10 MB)")
            return
        }
        do {
            var data = try Data(contentsOf: source)
            if let text = String(data: data, encoding: .utf8) {
                let findings = SecretScan.findings(in: text)
                guard findings.isEmpty else {
                    report.skipped.append("\(label) (contains a \(findings.joined(separator: ", ")))")
                    return
                }
                data = Data(text.replacingOccurrences(of: home.path, with: homeToken).utf8)
            }
            try write(data, to: destination, permissions: attributes[.posixPermissions] as? Int ?? 0o644)
            report.files += 1
        } catch {
            report.skipped.append("\(label) (couldn't copy: \(error.localizedDescription))")
        }
    }

    static func render(_ data: Data, home: URL, secrets: [String: String]) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        return Data(fill(text.replacingOccurrences(of: homeToken, with: home.path), secrets: secrets).utf8)
    }

    /// Equal, or equal once each `{{secret:…}}` in the template stands for whatever value the file holds.
    static func matches(_ existing: Data, template: Data) -> Bool {
        if existing == template { return true }
        guard let templateText = String(data: template, encoding: .utf8),
              let existingText = String(data: existing, encoding: .utf8),
              !SecretScan.placeholders(in: templateText).isEmpty else { return false }
        let pieces = templateText.split(separator: /\{\{secret:[A-Za-z0-9_.\-]+\}\}/, omittingEmptySubsequences: false)
        let pattern = "^" + pieces.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "(.+?)") + "$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return false }
        return regex.firstMatch(in: existingText, range: NSRange(existingText.startIndex..., in: existingText)) != nil
    }

    static func fill(_ text: String, secrets: [String: String]) -> String {
        var filled = text
        for (name, value) in secrets where !value.isEmpty {
            filled = filled.replacingOccurrences(of: SecretScan.placeholder(name), with: value)
        }
        return filled
    }

    static func write(_ data: Data, to url: URL, permissions: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    static func readJSON(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return (try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) ?? [:]
    }

    static func jsonText(_ object: Any, pretty: Bool = true) throws -> String {
        let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: options), as: UTF8.self)
    }

    static func writeJSON(_ object: Any, to url: URL) throws {
        try write(Data(try jsonText(object).utf8), to: url, permissions: 0o600)
    }

    static func pluginList(claude: URL) throws -> (plugins: [String], marketplaces: [ClaudeMarketplace]) {
        let installed = try readJSON(claude.appendingPathComponent("plugins/installed_plugins.json"))
        let plugins = ((installed["plugins"] as? [String: Any]) ?? [:]).keys.sorted()
        let known = try readJSON(claude.appendingPathComponent("plugins/known_marketplaces.json"))
        let marketplaces = known.keys.sorted().compactMap { name -> ClaudeMarketplace? in
            guard let entry = known[name] as? [String: Any], let source = entry["source"] as? [String: Any] else { return nil }
            let location = (source["repo"] ?? source["url"] ?? source["path"]) as? String
            return location.map { ClaudeMarketplace(name: name, source: $0) }
        }
        return (plugins, marketplaces)
    }

    static func mcpServers(in claudeJSON: [String: Any]) -> [(name: String, projectPath: String?, config: [String: Any], id: String)] {
        var servers: [(name: String, projectPath: String?, config: [String: Any], id: String)] = []
        for (name, config) in (claudeJSON["mcpServers"] as? [String: Any] ?? [:]) {
            if let config = config as? [String: Any] { servers.append((name, nil, config, "/\(name)")) }
        }
        for (path, project) in (claudeJSON["projects"] as? [String: Any] ?? [:]) {
            for (name, config) in ((project as? [String: Any])?["mcpServers"] as? [String: Any] ?? [:]) {
                if let config = config as? [String: Any] { servers.append((name, path, config, "\(path)/\(name)")) }
            }
        }
        return servers.sorted { $0.id < $1.id }
    }
}
