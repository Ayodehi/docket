import ReviewCore
import SwiftUI
import Workspace

/// Dense, sortable table of the current scope, grouped by repo, state, author, or not at all.
struct PRTableView: View {
    @Environment(AppState.self) private var app
    /// Hides the column the rows are grouped by; the section header already shows it.
    @State private var columns = TableColumnCustomization<PRSnapshot>()

    /// Narrowest the table pane gets; columns scroll horizontally below their ideal widths.
    static let minimumWidth: CGFloat = 420

    var body: some View {
        @Bindable var browser = app.browser
        let visible = Browse.visible(app.snapshots, scope: browser.scope, text: browser.searchText, rules: app.rules)
        let sorted = visible.sorted(using: browser.tableSort)
        let grouping = app.viewSettings.tableGrouping
        let sections = Self.sections(sorted, by: grouping, sort: browser.tableSort)
        let folds = Dictionary(sections.map {
            ($0.id, Stacks.fold($0.items, positions: app.stacks, collapsed: app.collapsedStacks))
        }, uniquingKeysWith: { first, _ in first })
        let followers = folds.values.reduce(into: [String: [PRSnapshot]]()) { $0.merge($1.followers) { first, _ in first } }
        Group {
            if visible.isEmpty {
                ContentUnavailableView(browser.searchText.isEmpty ? "No PRs" : "No matches", systemImage: "tablecells",
                                       description: Text(browser.searchText.isEmpty ? "Nothing in \(browser.scope.title)." : "Try repo:, author:, state:, or label: filters."))
            } else {
                Table(of: PRSnapshot.self, selection: $browser.selection, sortOrder: $browser.tableSort, columnCustomization: $columns) {
                    TableColumn("PR", value: \.number) { pr in
                        Text("#\(pr.number)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(min: 48, ideal: 60, max: 80)
                    TableColumn("Title", value: \.title) { pr in
                        HStack(spacing: 4) {
                            if let followers = followers[pr.id] { StackToggle(pr: pr, followers: followers) }
                            if let depth = app.stacks[pr.id]?.depth, depth > 0 {
                                Image(systemName: "arrow.turn.down.right").foregroundStyle(Tone.accent.text)
                                    .padding(.leading, CGFloat(StackIndent.level(depth) - 1) * 12)
                                    .help("Stacked on #\(app.stacks[pr.id]?.parentID.flatMap(app.snapshot(id:))?.number ?? 0)")
                            }
                            if app.snoozed.contains(pr.id) {
                                Image(systemName: "moon.fill").foregroundStyle(.secondary).accessibilityLabel("Snoozed")
                            }
                            Text(pr.title).lineLimit(1)
                        }
                        .help(pr.title)
                    }
                    .width(min: 120, ideal: 360)
                    TableColumn("Repo", value: \.repoName) { Text($0.repoName).lineLimit(1) }
                        .width(min: 60, ideal: 130)
                        .customizationID(TableGrouping.repo.rawValue).disabledCustomizationBehavior(.all)
                    TableColumn("Author", value: \.author) { pr in
                        Text(pr.isMine ? "you" : pr.author).lineLimit(1)
                    }
                    .width(min: 50, ideal: 110)
                    .customizationID(TableGrouping.author.rawValue).disabledCustomizationBehavior(.all)
                    TableColumn("State", value: \.stateRank) { Chip(state: $0.primary) }
                        .width(min: 100, ideal: 140)
                        .customizationID(TableGrouping.state.rawValue).disabledCustomizationBehavior(.all)
                    TableColumn("CI", value: \.ciRank) { Chip(ci: $0.ci, short: false) }
                        .width(min: 70, ideal: 110)
                    TableColumn("Review", value: \.reviewRank) { Text($0.review.title).foregroundStyle(.secondary) }
                        .width(min: 80, ideal: 120)
                    TableColumn("Merge", value: \.mergeRank) { pr in
                        Text(pr.merge.title).foregroundStyle(pr.merge.tone.text)
                    }
                    .width(min: 70, ideal: 110)
                    TableColumn("Threads", value: \.unresolvedThreads) { pr in
                        Text(pr.unresolvedThreads == 0 ? "" : "\(pr.unresolvedThreads)").monospacedDigit()
                    }
                    .width(min: 40, ideal: 56, max: 70)
                    TableColumn("Updated", value: \.updatedAt) { pr in
                        Text(Age.short(since: pr.updatedAt)).monospacedDigit().foregroundStyle(.secondary)
                            .help(pr.updatedAt.formatted())
                    }
                    .width(min: 50, ideal: 64, max: 90)
                } rows: {
                    ForEach(sections) { section in
                        Section {
                            ForEach(folds[section.id]?.items ?? section.items) { pr in
                                TableRow(pr).contextMenu { RowMenu(pr: pr) }
                            }
                        } header: {
                            if !section.title.isEmpty {
                                Text("\(section.title) · \(section.items.count)")
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: grouping, initial: true) { _, grouping in
            for column in [TableGrouping.repo, .author, .state] {
                columns[visibility: column.rawValue] = column == grouping ? .hidden : .visible
            }
        }
    }

    static func sections(_ prs: [PRSnapshot], by grouping: TableGrouping, sort: [KeyPathComparator<PRSnapshot>]) -> [PRSection] {
        let grouped: [PRSection] = switch grouping {
        case .none: [PRSection(id: "all", title: "", items: prs)]
        case .repo: Browse.sectionsByRepo(prs)
        case .state: Browse.sectionsByState(prs)
        case .author: Browse.sectionsByAuthor(prs).map { section in
            // Rows show "you" for my PRs; match that in the group header.
            section.items.first?.isMine == true ? PRSection(id: section.id, title: "You", items: section.items) : section
        }
        }
        // Groups keep their order; rows inside follow the column sort.
        return grouped.map { PRSection(id: $0.id, title: $0.title, items: $0.items.sorted(using: sort)) }
    }
}

/// Right-click menu shared by table rows.
struct RowMenu: View {
    @Environment(AppState.self) private var app
    let pr: PRSnapshot

    var body: some View {
        Button("Open on GitHub") { app.openOnGitHub(pr) }
        Button(PromptKind.forState(pr).actionTitle) { app.startClaude(pr) }
        if let profile = app.runSettings(for: pr.repo).defaultProfile {
            Button("Run \(profile.name)") { app.startRun(pr, profile: profile) }
            if profile.hasStop { Button("Stop \(profile.name)") { app.stopRun(pr, profile: profile) } }
        }
        Divider()
        StackMenuItem(pr: pr)
        SnoozeMenuItems(pr: pr)
    }
}
