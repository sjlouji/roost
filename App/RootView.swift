import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: Sheet?

    enum Sheet: Identifiable {
        case addAccount, addProject
        var id: Self { self }
    }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("GitHub accounts") {
                    ForEach(model.state.accounts) { account in
                        Label(account.label, systemImage: "person.crop.circle").tag(SidebarItem.account(account.id))
                    }
                }
                Section("Projects") {
                    ForEach(model.state.projects) { project in
                        Label(project.name, systemImage: "folder").tag(SidebarItem.project(project.id))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .toolbar {
                ToolbarItem {
                    Menu {
                        Button("New GitHub account…") { sheet = .addAccount }
                        Button("Import accounts from ~/.ssh/config") { model.importAccounts() }
                        Divider()
                        Button("New project…") { sheet = .addProject }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .disabled(model.runningTask != nil)
                }
            }
        } detail: {
            VStack(spacing: 0) {
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ActivityLog().frame(height: 180)
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .addAccount: AddAccountSheet()
            case .addProject: AddProjectSheet()
            }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.selection {
        case .account(let id):
            if let account = model.account(id) { AccountDetail(account: account) }
        case .project(let id):
            if let project = model.project(id) { ProjectDetail(project: project) }
        case nil:
            ContentUnavailableView(
                "Welcome to Roost",
                systemImage: "bird",
                description: Text("Add a GitHub account or a project with the + button, or import the accounts already in ~/.ssh/config.")
            )
        }
    }
}

struct ActivityLog: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Activity").font(.headline)
                if let task = model.runningTask {
                    ProgressView().controlSize(.small)
                    Text(task).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Clear") { model.log.removeAll() }
                    .buttonStyle(.borderless)
                    .disabled(model.log.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.log.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                .onChange(of: model.log.count) { _, count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
        .background(.background.secondary)
    }
}
