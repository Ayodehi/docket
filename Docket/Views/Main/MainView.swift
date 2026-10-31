import ReviewCore
import SwiftUI

struct MainView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Group {
            switch app.session {
            case .loading:
                ProgressView()
            case .signedOut, .needsReauth:
                ScrollView {
                    SignInView().frame(maxWidth: 460).padding(32)
                }
            case .signedIn, .ssoRequired:
                BrowserView()
            }
        }
        .onAppear {
            app.surfaceAppeared()
            app.mainWindowVisibilityChanged(true)
        }
        .onDisappear {
            app.surfaceDisappeared()
            app.mainWindowVisibilityChanged(false)
        }
        .allowsFullScreen()
        .alert(app.workspaceAlert?.title ?? "", isPresented: Binding(get: { app.workspaceAlert != nil }, set: { if !$0 { app.workspaceAlert = nil } }),
               presenting: app.workspaceAlert) { alert in
            ForEach(Array(alert.actions.enumerated()), id: \.offset) { _, action in
                Button(action.title, role: action.role) { action.run() }
            }
        } message: { alert in
            Text(alert.message)
        }
    }
}

private struct BrowserView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var browser = app.browser
        Group {
            if app.presentation == .list {
                NavigationSplitView {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 260)
                } content: {
                    PRListView()
                        .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 480)
                } detail: {
                    detail
                }
            } else {
                NavigationSplitView {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 260)
                } detail: {
                    // The inspector may grow until the table reaches its minimum width. A fixed maximum
                    // larger than the window allows made the split view's layout unsatisfiable and
                    // crashed AppKit's constraint pass.
                    GeometryReader { geometry in
                        Group {
                            if app.presentation == .board { PRBoardView() } else { PRTableView() }
                        }
                            .frame(minWidth: PRTableView.minimumWidth)
                            .inspector(isPresented: Binding(get: { app.viewSettings.showInspector }, set: { app.viewSettings.showInspector = $0 })) {
                                detail.inspectorColumnWidth(min: 320, ideal: 440,
                                                            max: max(320, geometry.size.width - PRTableView.minimumWidth))
                            }
                    }
                }
            }
        }
        .navigationTitle(browser.scope.title)
        .searchable(text: $browser.searchText, placement: .toolbar, prompt: "Search, or repo: author: state: label:")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Presentation", selection: Binding(get: { app.presentation }, set: { app.presentation = $0 })) {
                    Label("List", systemImage: "list.bullet").tag(Presentation.list)
                    Label("Board", systemImage: "rectangle.split.3x1").tag(Presentation.board)
                    Label("Table", systemImage: "tablecells").tag(Presentation.table)
                }
                .pickerStyle(.segmented)
                .help("Show this view as a list, board, or table (Control-Command-1, 2, 3). Remembered per view.")
            }
            if app.presentation != .list {
                // Table and board controls share one capsule, kept apart from the sync status below.
                ToolbarItemGroup {
                    if app.presentation == .table {
                        Menu {
                        Picker("Group by", selection: Binding(get: { app.viewSettings.tableGrouping }, set: { app.viewSettings.tableGrouping = $0 })) {
                            ForEach(TableGrouping.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.inline)
                        } label: {
                            Label("Group by \(app.viewSettings.tableGrouping.title)", systemImage: "rectangle.3.group")
                        }
                        .help("Group rows")
                    }
                    Button { app.viewSettings.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                        .help("Show or hide the inspector (Option-Command-I)")
                }
            }
            SyncStatusToolbarContent()
            ToolbarItem {
                Button { app.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r")
                    .help("Refresh now (Command-R)")
                    .disabled(app.isSyncing)
            }
        }
        .onChange(of: browser.selection) { _, id in
            if let id { app.markViewed(id) }
        }
    }

    @ViewBuilder private var detail: some View {
        if let pr = app.snapshot(id: app.browser.selection) {
            PRDetailView(pr: pr)
        } else {
            ContentUnavailableView("No PR selected", systemImage: "sidebar.right", description: Text("Select a PR to see checks, reviewers, and actions."))
        }
    }
}

private struct SidebarView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var repoToHide: String?

    var body: some View {
        @Bindable var browser = app.browser
        List(selection: $browser.scope) {
            Section {
                row(.inbox, "tray")
                row(.mine, "person")
                row(.reviewing, "eye")
                row(.snoozed, "moon")
            }
            Section("Repos") {
                ForEach(app.repos, id: \.name) { repo in
                    Label(Scope.repo(repo.name).title, systemImage: app.mutedRepos.contains(repo.name) ? "bell.slash" : "folder")
                        .badge(repo.count)
                        .help(app.mutedRepos.contains(repo.name) ? "\(repo.name) (notifications muted)" : repo.name)
                        .tag(Scope.repo(repo.name))
                        .contextMenu {
                            Button(app.mutedRepos.contains(repo.name) ? "Unmute Notifications" : "Mute Notifications") { app.toggleMute(repo.name) }
                            Button("Hide Repo…") { repoToHide = repo.name }
                        }
                }
            }
        }
        .confirmationDialog("Hide \(repoToHide ?? "")?", isPresented: Binding(get: { repoToHide != nil }, set: { if !$0 { repoToHide = nil } })) {
            Button("Hide Repo") {
                if let repo = repoToHide { app.setHidden(repo, true) }
                repoToHide = nil
            }
        } message: {
            Text("Its PRs leave every view and it stops syncing. Show it again from Settings > Inbox.")
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                if app.loadingCount > 0 {
                    Label("Loading \(app.loadingCount) PRs…", systemImage: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button { openWindow(id: "worktrees") } label: {
                    Label("Worktrees", systemImage: "arrow.triangle.branch")
                }
                .buttonStyle(.borderless)
                .help("Every worktree of your clones, with cleanup (Option-Command-T)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
    }

    private func row(_ scope: Scope, _ symbol: String) -> some View {
        Label(scope.title, systemImage: symbol)
            .badge(app.count(scope))
            .tag(scope)
    }
}

/// Sync status as plain toolbar text. On macOS 26 and later toolbar items share glass capsules
/// with their neighbors, so the status gets a spacer before it and no capsule of its own; that keeps
/// the table controls from merging into it.
struct SyncStatusToolbarContent: ToolbarContent {
    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed)
            ToolbarItem {
                SyncStatusText()
                    .padding(.horizontal, 6)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem {
                SyncStatusText()
                    .padding(.horizontal, 10)
            }
        }
    }
}

struct SyncStatusText: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Group {
            if app.isSyncing {
                Text("Syncing…")
            } else if let error = app.syncError {
                Label(error, systemImage: "exclamationmark.triangle").labelStyle(.titleAndIcon)
                    .help(error)
            } else if let last = app.lastSync {
                TimelineView(.periodic(from: .now, by: 15)) { _ in
                    Text("Synced \(Age.short(since: last)) ago")
                }
                .foregroundStyle(app.isStale ? Tone.warn.text : .secondary)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}
