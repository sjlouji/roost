import AppKit
import RoostCore
import SwiftUI

struct ClaudePage: View {
    @Environment(AppModel.self) private var model
    @State private var includePersonal = true
    @State private var includeMemory = true

    var body: some View {
        @Bindable var model = model
        Form {
            if let inventory = model.claude {
                Section("Instructions") {
                    LabeledContent("CLAUDE.md", value: inventory.hasClaudeMD ? "Set up" : "None")
                    NameList(title: "Rules", names: inventory.rules)
                    LabeledContent("settings.json", value: inventory.hasSettings ? "Set up" : "None")
                }
                Section("Agents, commands and hooks") {
                    NameList(title: "Agents", names: inventory.agents)
                    NameList(title: "Commands", names: inventory.commands)
                    NameList(title: "Hooks", names: inventory.hooks)
                }
                Section {
                    DisclosureGroup("\(inventory.skills.count) skill(s)") {
                        ForEach(inventory.skills) { skill in
                            LabeledContent(skill.name) {
                                Text(skillSize(skill)).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Skills")
                } footer: {
                    Text("Dependency folders inside skills (node_modules, .venv…) are left out of exports; reinstall them on the other Mac.")
                }
                Section("Plugins") {
                    NameList(title: "Installed", names: inventory.plugins)
                    NameList(title: "Marketplaces", names: inventory.marketplaces.map { "\($0.name) · \($0.source)" })
                }
                Section("MCP servers") {
                    if inventory.mcpServers.isEmpty { Text("None").foregroundStyle(.secondary) }
                    ForEach(inventory.mcpServers) { server in
                        LabeledContent(server.name) {
                            Text(server.projectPath.map(Paths.abbreviate) ?? "All projects").foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    DisclosureGroup("\(inventory.memory.count) project(s) with memory") {
                        ForEach(inventory.memory) { memory in
                            LabeledContent {
                                Text("\(memory.files) file(s)").foregroundStyle(.secondary)
                            } label: {
                                if let path = memory.projectPath {
                                    Text(Paths.abbreviate(path))
                                } else {
                                    Label(memory.folder, systemImage: "questionmark.folder").foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Memory")
                } footer: {
                    if inventory.memory.contains(where: { $0.projectPath == nil }) {
                        Text("Orange entries belong to folders that no longer exist; they're left out of exports.")
                    }
                }
            } else {
                ProgressView("Reading ~/.claude…")
            }

            Section {
                Toggle("Include my CLAUDE.md and rules", isOn: $includePersonal)
                Toggle("Include memory", isOn: $includeMemory)
                HStack {
                    Button("Export…", action: export)
                    Button("Import…", action: importBundle)
                }
                .disabled(model.runningTask != nil)
            } header: {
                Text("Move to another Mac")
            } footer: {
                Text("Export writes a folder you can copy to the other Mac and import there. Keys and tokens are replaced with placeholders you fill in when importing. Your login, history, sessions and caches are never included. Turn both toggles off when exporting for someone else.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Claude Code")
        .sheet(item: $model.claudeImportPlan) { plan in ClaudeImportSheet(plan: plan) }
        .sheet(item: $model.claudeExportReport) { report in
            ClaudeReportSheet(
                title: "Export finished",
                lines: ["\(report.files) file(s) and \(report.memoryFolders) memory folder(s) exported."]
                    + report.scrubbed.map { "Replaced with a placeholder: \($0)" }
                    + report.skipped.map { "Left out: \($0)" }
            )
        }
        .sheet(item: $model.claudeImportReport) { report in
            ClaudeReportSheet(
                title: report.failures.isEmpty ? "Import finished" : "Import finished with problems",
                lines: ["\(report.written) file(s) written into ~/.claude."]
                    + (report.backupFolder.map { ["Replaced files were backed up to \(Paths.abbreviate($0.path))."] } ?? [])
                    + report.failures.map { "Needs attention: \($0)" }
                    + ["Restart Claude Code to pick up the changes."]
            )
        }
    }

    private func skillSize(_ skill: ClaudeSkill) -> String {
        let kept = ByteCountFormatter.string(fromByteCount: skill.bytes - skill.skippedBytes, countStyle: .file)
        guard skill.skippedBytes > 0 else { return kept }
        return "\(kept) + \(ByteCountFormatter.string(fromByteCount: skill.skippedBytes, countStyle: .file)) dependencies"
    }

    private func export() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Roost creates a claude-setup folder inside the folder you pick."
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let stamp = Date.now.formatted(.iso8601.year().month().day())
        model.exportClaude(
            to: parent.appendingPathComponent("claude-setup-\(stamp)"),
            options: ClaudeExportOptions(includePersonal: includePersonal, includeMemory: includeMemory)
        )
    }

    private func importBundle() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Import"
        panel.message = "Pick a claude-setup folder that Roost exported."
        guard panel.runModal() == .OK, let bundle = panel.url else { return }
        model.planClaudeImport(from: bundle)
    }
}

/// A count that expands into the names.
struct NameList: View {
    let title: String
    let names: [String]

    var body: some View {
        if names.isEmpty {
            LabeledContent(title, value: "None")
        } else {
            DisclosureGroup("\(title): \(names.count)") {
                ForEach(names, id: \.self) { Text($0).font(.callout) }
            }
        }
    }
}

struct ClaudeImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let plan: ClaudeImportPlan
    @State private var secrets: [String: String] = [:]

    private func count(_ status: ClaudeImportPlan.File.Status) -> Int { plan.files.filter { $0.status == status }.count }

    var body: some View {
        Form {
            Section {
                LabeledContent("New files", value: "\(count(.new))")
                LabeledContent("Files that will replace yours", value: "\(count(.changed))")
                LabeledContent("Already the same", value: "\(count(.same))")
                let changed = plan.files.filter { $0.status == .changed }
                if !changed.isEmpty {
                    DisclosureGroup("Files that will be replaced") {
                        ForEach(changed) { Text($0.label).font(.callout) }
                    }
                }
            } header: {
                Text("Files")
            } footer: {
                Text("Replaced files are backed up to ~/.claude/backups first.")
            }
            if !plan.marketplaces.isEmpty || !plan.plugins.isEmpty || !plan.mcpServers.isEmpty {
                Section("Will install") {
                    NameList(title: "Marketplaces", names: plan.marketplaces.map { "\($0.name) · \($0.source)" })
                    NameList(title: "Plugins", names: plan.plugins)
                    NameList(title: "MCP servers", names: plan.mcpServers.map { server in
                        server.projectPath.map { "\(server.name) · \(Paths.abbreviate($0))" } ?? server.name
                    })
                }
            }
            if !plan.secretsNeeded.isEmpty {
                Section {
                    ForEach(plan.secretsNeeded, id: \.self) { name in
                        SecureField(name, text: Binding(get: { secrets[name, default: ""] }, set: { secrets[name] = $0 }))
                    }
                } header: {
                    Text("Secrets to fill in")
                } footer: {
                    Text("These were replaced with placeholders when exporting. Leave one empty to fill it in later; Roost will tell you which file it's in.")
                }
            }
            if !plan.skipped.isEmpty {
                Section("Skipped") {
                    ForEach(plan.skipped, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 560)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Import") {
                    model.applyClaudeImport(plan, secrets: secrets)
                    dismiss()
                }
            }
        }
    }
}

struct ClaudeReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(lines, id: \.self) { Text($0).textSelection(.enabled) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
    }
}
