import ReviewCore
import SwiftUI

struct PRListView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var browser = app.browser
        let visible = Browse.visible(app.snapshots, scope: browser.scope, text: browser.searchText, rules: app.rules)
        let sections = Browse.sectionsByMove(visible)
        Group {
            if sections.isEmpty {
                emptyState
            } else {
                List(selection: $browser.selection) {
                    ForEach(sections) { section in
                        Section {
                            let fold = Stacks.fold(section.items, positions: app.stacks, collapsed: app.collapsedStacks)
                            ForEach(fold.items) { pr in
                                PRRow(pr: pr, isSnoozed: app.snoozed.contains(pr.id), stack: app.stacks[pr.id],
                                      parentNumber: app.stacks[pr.id]?.parentID.flatMap(app.snapshot(id:))?.number,
                                      followers: fold.followers[pr.id] ?? []).tag(pr.id)
                                    .contextMenu {
                                        StackMenuItem(pr: pr)
                                        SnoozeMenuItems(pr: pr)
                                    }
                            }
                        } header: {
                            HStack {
                                Text(section.title)
                                Spacer()
                                Text("\(section.items.count)").monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if app.ssoPartial {
                HStack {
                    Label("Some organizations hide PRs until this token is authorized for SAML SSO.", systemImage: "lock.shield")
                    Spacer()
                    Link("Authorize…", destination: URL(string: "https://github.com/settings/tokens")!)
                }
                .font(.callout)
                .foregroundStyle(Tone.warn.text)
                .padding(8)
                .background(Tone.warn.base.opacity(0.12))
            }
            if app.isStale, let error = app.syncError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(Tone.warn.text)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Tone.warn.base.opacity(0.12))
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !app.browser.searchText.isEmpty {
            ContentUnavailableView.search(text: app.browser.searchText)
        } else if app.snapshots.isEmpty && (app.isSyncing || app.loadingCount > 0) {
            ContentUnavailableView("Loading pull requests", systemImage: "arrow.clockwise")
        } else {
            switch app.browser.scope {
            case .inbox:
                ContentUnavailableView("Nothing needs you", systemImage: "checkmark.circle", description: Text("Review requests and your PRs that need action show up here."))
            case .snoozed:
                ContentUnavailableView("No snoozed PRs", systemImage: "moon", description: Text("Snooze a PR from its detail, the menu bar, or a notification."))
            default:
                ContentUnavailableView("No open PRs", systemImage: "tray")
            }
        }
    }
}

struct PRRow: View {
    let pr: PRSnapshot
    var isSnoozed = false
    var stack: StackPosition?
    var parentNumber: Int?
    /// Set on the first row of a stack run: the other members, for the collapse toggle.
    var followers: [PRSnapshot] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if !followers.isEmpty { StackToggle(pr: pr, followers: followers) }
                Chip(state: pr.primary)
                if isSnoozed {
                    Image(systemName: "moon.fill").foregroundStyle(.secondary).help("Snoozed").accessibilityLabel("Snoozed")
                }
                Spacer()
                Text(Age.short(since: pr.stateEnteredAt))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help("In this state since \(pr.stateEnteredAt.formatted())")
            }
            Text(pr.title)
                .font(.body.weight(.medium))
                .lineLimit(1)
            HStack(spacing: 6) {
                if let parentNumber {
                    Label("on #\(parentNumber)", systemImage: "arrow.turn.down.right")
                        .font(.caption).foregroundStyle(Tone.accent.text).lineLimit(1)
                        .help("Stacked on #\(parentNumber)")
                } else if let stack, stack.memberIDs.count > 1 {
                    Label("stack of \(stack.memberIDs.count)", systemImage: "square.stack.3d.up")
                        .font(.caption).foregroundStyle(Tone.accent.text).lineLimit(1)
                }
                Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Chip(ci: pr.ci)
            }
        }
        .padding(.vertical, 4)
        .padding(.leading, CGFloat(StackIndent.level(stack?.depth ?? 0)) * 10)
        .opacity(pr.primary.isMyMove ? 1 : 0.8)
        .accessibilityElement(children: .combine)
    }

    private var meta: String {
        var parts = ["\(pr.repoName) #\(pr.number)", pr.isMine ? "yours" : pr.author]
        if pr.unresolvedThreads > 0 { parts.append("\(pr.unresolvedThreads) thread\(pr.unresolvedThreads == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

/// Snooze choices, shared by context menus and the detail pane.
struct SnoozeMenuItems: View {
    @Environment(AppState.self) private var app
    let pr: PRSnapshot

    var body: some View {
        if app.snoozed.contains(pr.id) {
            Button("Unsnooze") { app.unsnooze(pr.id) }
        } else {
            Button("Snooze for 1 Hour") { app.snooze(pr.id, .oneHour) }
            Button("Snooze Until Tomorrow 9:00") { app.snooze(pr.id, .tomorrow) }
            Button("Snooze Until It Changes") { app.snooze(pr.id, .untilChange) }
        }
    }
}
