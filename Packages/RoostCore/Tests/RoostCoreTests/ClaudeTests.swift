import Foundation
import Testing
@testable import RoostCore

@Suite struct ClaudeSetupTests {
    /// A fake home with a small but complete Claude Code setup, including things export must leave out.
    func makeHome() throws -> URL {
        let home = try makeTempDirectory().resolvingSymlinksInPath()
        let claude = home.appendingPathComponent(".claude")
        try write("Notes live in \(home.path)/Documents/notes\n", to: claude.appendingPathComponent("CLAUDE.md"))
        try write("# Rule\n", to: claude.appendingPathComponent("rules/style.md"))
        try write("# Agent\n", to: claude.appendingPathComponent("agents/reviewer.md"))
        try write("token = ghp_abcdefghijklmnopqrstuvwxyz0123456789\n", to: claude.appendingPathComponent("agents/leaky.md"))
        let hook = claude.appendingPathComponent("hooks/check.sh")
        try write("#!/bin/sh\n\(home.path)/bin/run\n", to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try write("# Skill\n", to: claude.appendingPathComponent("skills/deploy/SKILL.md"))
        try write("Connect with postgres://user:password@localhost/db or key AKIAIOSFODNN7EXAMPLE\n", to: claude.appendingPathComponent("skills/deploy/reference.md"))
        try write("module.exports = 1\n", to: claude.appendingPathComponent("skills/deploy/node_modules/dep/index.js"))
        try write("managed\n", to: claude.appendingPathComponent("skills/synced/x/SKILL.md"))
        try write("""
        {"env": {"GITHUB_TOKEN": "ghp_abcdefghijklmnopqrstuvwxyz0123456789", "EDITOR": "vim"},
         "permissions": {"allow": ["Bash(git status)", "Bash(export AWS_ACCESS_KEY_ID=AKIAABCDEFGHIJKLMNOP)", "Bash(export AWS_SECRET_ACCESS_KEY=\\"wJalrXUtnFEMIK7MDENGbPxRfiCYab12cd34ef\\")", "Bash(psql postgresql://app:app@localhost:5432/app)"]},
         "hooks": {"Stop": [{"command": "\(home.path)/.claude/hooks/check.sh"}]}}
        """, to: claude.appendingPathComponent("settings.json"))
        try write("""
        {"version": 2, "plugins": {"review@official": [{"scope": "user"}]}}
        """, to: claude.appendingPathComponent("plugins/installed_plugins.json"))
        try write("""
        {"official": {"source": {"source": "github", "repo": "acme/plugins"}, "installLocation": "/x"}}
        """, to: claude.appendingPathComponent("plugins/known_marketplaces.json"))
        try write("""
        {"oauthAccount": {"email": "me@example.com"}, "userID": "abc",
         "mcpServers": {"tracker": {"type": "http", "url": "https://mcp.example.com", "headers": {"Authorization": "Bearer abcdefghijklmnopqrstuvwxyz"}}},
         "projects": {"\(home.path)/Documents/app": {"mcpServers": {"db": {"command": "db-mcp", "env": {"DB_PASSWORD": "hunter2", "DB_HOST": "localhost"}}}}}}
        """, to: home.appendingPathComponent(".claude.json"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Documents/app"), withIntermediateDirectories: true)
        let appMemory = ClaudeSetup.encodeProjectPath(home.appendingPathComponent("Documents/app").path)
        try write("- remembers things\n", to: claude.appendingPathComponent("projects/\(appMemory)/memory/MEMORY.md"))
        let staleMemory = ClaudeSetup.encodeProjectPath(home.appendingPathComponent("Documents/gone").path)
        try write("- stale\n", to: claude.appendingPathComponent("projects/\(staleMemory)/memory/MEMORY.md"))
        try write("{}\n", to: claude.appendingPathComponent("history.jsonl"))
        return home
    }

    @Test func encodesAndResolvesProjectFolders() throws {
        let home = try makeTempDirectory().resolvingSymlinksInPath()
        let folder = home.appendingPathComponent("my_app.v2/sub dir")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoded = ClaudeSetup.encodeProjectPath(folder.path)
        #expect(!encoded.contains("/") && !encoded.contains("_") && !encoded.contains(" "))
        #expect(ClaudeSetup.resolveProjectFolder(encoded) == folder.path)
        #expect(ClaudeSetup.resolveProjectFolder(encoded + "-missing") == nil)
    }

    @Test func inventoryShowsWhatIsSetUp() throws {
        let home = try makeHome()
        let inventory = try ClaudeSetup.inventory(home: home)
        #expect(inventory.hasClaudeMD && inventory.hasSettings)
        #expect(inventory.agents == ["leaky.md", "reviewer.md"])
        #expect(inventory.skills.map(\.name) == ["deploy"])
        #expect(inventory.skills[0].skippedBytes > 0)
        #expect(inventory.plugins == ["review@official"])
        #expect(inventory.marketplaces == [ClaudeMarketplace(name: "official", source: "acme/plugins")])
        #expect(Set(inventory.mcpServers.map(\.name)) == ["tracker", "db"])
        #expect(inventory.memory.count == 2)
        #expect(inventory.memory.filter { $0.projectPath == nil }.count == 1)
    }

    @Test func exportScrubsSecretsAndLeavesOutPrivateData() throws {
        let home = try makeHome()
        let bundle = try makeTempDirectory().appendingPathComponent("export")

        let report = try ClaudeSetup.export(to: bundle, home: home, options: .init(includePersonal: true, includeMemory: true))

        let out = bundle.appendingPathComponent("claude")
        let read = { (path: String) in try String(contentsOf: bundle.appendingPathComponent(path), encoding: .utf8) }
        #expect(try read("claude/CLAUDE.md") == "Notes live in {{HOME}}/Documents/notes\n")
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("agents/leaky.md").path))
        #expect(report.skipped.contains { $0.hasPrefix("agents/leaky.md") })
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("skills/deploy/node_modules").path))
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("skills/synced").path))
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("history.jsonl").path))
        let hookPermissions = try FileManager.default.attributesOfItem(atPath: out.appendingPathComponent("hooks/check.sh").path)[.posixPermissions] as? Int
        #expect(hookPermissions == 0o755)

        let settings = try read("claude/settings.json")
        #expect(settings.contains("{{secret:GITHUB_TOKEN}}") && settings.contains("vim") && settings.contains("{{HOME}}/.claude/hooks"))
        #expect(settings.contains("Bash(git status)") && settings.contains("@localhost:5432/app"))
        #expect(!settings.contains("AKIAABCDEFGHIJKLMNOP") && !settings.contains("wJalrXUtnFEMIK7MDENG"))
        #expect(report.scrubbed.contains("settings.json: 2 permission rule(s) containing a secret were left out"))
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("skills/deploy/reference.md").path))
        let mcp = try read("mcp.json")
        #expect(mcp.contains("{{secret:tracker_Authorization}}") && mcp.contains("{{secret:db_DB_PASSWORD}}") && mcp.contains("localhost"))
        #expect(mcp.contains("{{HOME}}/Documents/app"))
        #expect(!mcp.contains("hunter2") && !mcp.contains("Bearer abc"))
        #expect(try read("memory/Documents/app/MEMORY.md") == "- remembers things\n")
        #expect(report.skipped.contains { $0.hasPrefix("memory for") })
        #expect(!(try read("manifest.json")).contains("me@example.com"))
        #expect(throws: RoostError.self) {
            try ClaudeSetup.export(to: bundle, home: home, options: .init(includePersonal: true, includeMemory: true))
        }
    }

    @Test func exportForSomeoneElseLeavesOutPersonalFiles() throws {
        let home = try makeHome()
        let bundle = try makeTempDirectory().appendingPathComponent("export")
        _ = try ClaudeSetup.export(to: bundle, home: home, options: .init(includePersonal: false, includeMemory: false))
        #expect(!FileManager.default.fileExists(atPath: bundle.appendingPathComponent("claude/CLAUDE.md").path))
        #expect(!FileManager.default.fileExists(atPath: bundle.appendingPathComponent("claude/rules").path))
        #expect(!FileManager.default.fileExists(atPath: bundle.appendingPathComponent("memory").path))
        #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("claude/agents/reviewer.md").path))
    }

    @Test func importPlansThenWritesIntoANewHome() async throws {
        let bundle = try makeTempDirectory().appendingPathComponent("export")
        _ = try ClaudeSetup.export(to: bundle, home: try makeHome(), options: .init(includePersonal: true, includeMemory: true))
        let newHome = try makeTempDirectory().resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: newHome.appendingPathComponent("Documents/app"), withIntermediateDirectories: true)
        try write("old instructions\n", to: newHome.appendingPathComponent(".claude/CLAUDE.md"))

        var plan = try ClaudeSetup.plan(from: bundle, home: newHome)

        #expect(plan.secretsNeeded == ["GITHUB_TOKEN", "db_DB_PASSWORD", "tracker_Authorization"])
        #expect(plan.plugins == ["review@official"])
        #expect(plan.marketplaces.map(\.name) == ["official"])
        #expect(Set(plan.mcpServers.map(\.name)) == ["tracker", "db"])
        #expect(plan.files.first { $0.label == "CLAUDE.md" }?.status == .changed)

        // Plugins and MCP servers call the real claude CLI; this test covers the file side only.
        plan.plugins = []
        plan.marketplaces = []
        plan.mcpServers = []
        let report = try await ClaudeSetup.apply(plan, secrets: ["GITHUB_TOKEN": "ghp_new"], home: newHome)

        let claude = newHome.appendingPathComponent(".claude")
        let read = { (path: String) in try String(contentsOf: claude.appendingPathComponent(path), encoding: .utf8) }
        #expect(try read("CLAUDE.md").contains("\(newHome.path)/Documents/notes"))
        #expect(try read("settings.json").contains("ghp_new"))
        #expect(try read("settings.json").contains("\(newHome.path)/.claude/hooks/check.sh"))
        let memoryFolder = ClaudeSetup.encodeProjectPath(newHome.appendingPathComponent("Documents/app").path)
        #expect(try read("projects/\(memoryFolder)/memory/MEMORY.md") == "- remembers things\n")
        let backup = try #require(report.backupFolder)
        #expect(try String(contentsOf: backup.appendingPathComponent(".claude/CLAUDE.md"), encoding: .utf8) == "old instructions\n")
        #expect(report.failures.isEmpty)

        let again = try ClaudeSetup.plan(from: bundle, home: newHome)
        #expect(again.files.allSatisfy { $0.status == .same })
    }

    @Test func importReportsSecretsLeftUnfilled() async throws {
        let bundle = try makeTempDirectory().appendingPathComponent("export")
        _ = try ClaudeSetup.export(to: bundle, home: try makeHome(), options: .init(includePersonal: false, includeMemory: false))
        let newHome = try makeTempDirectory()
        var plan = try ClaudeSetup.plan(from: bundle, home: newHome)
        plan.plugins = []
        plan.marketplaces = []
        plan.mcpServers = []

        let report = try await ClaudeSetup.apply(plan, secrets: [:], home: newHome)

        #expect(report.failures == ["settings.json: GITHUB_TOKEN not filled in; edit the file to add it"])
    }
}
