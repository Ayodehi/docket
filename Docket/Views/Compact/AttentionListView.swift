import ReviewCore
import SwiftUI
import Workspace

/// The menu bar popover's list, also shown in the Compact window.
struct AttentionListView: View {
    enum Tab: String, CaseIterable { case move = "Your move", mine = "Mine", reviews = "Reviews" }

    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .move
    var isPopover = true
    private let limit = 10

    /// Popover width. Every row inside fills this width instead of sizing to its content, so
    /// nothing can push the panel wider than the menu bar window and get clipped.
    private static let popoverWidth: CGFloat = 380

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .modifier(SurfaceFrame(isPopover: isPopover, popoverWidth: Self.popoverWidth))
        .onAppear { app.surfaceAppeared() }
        .onDisappear { app.surfaceDisappeared() }
    }

    private var items: [PRSnapshot] {
        switch tab {
        case .move: app.inbox
        case .mine: Browse.sectionsByMove(Browse.visible(app.snapshots, scope: .mine, text: "", rules: app.rules)).flatMap(\.items)
        case .reviews: Browse.sectionsByMove(Browse.visible(app.snapshots, scope: .reviewing, text: "", rules: app.rules)).flatMap(\.items)
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(app.attentionCount == 0 ? "All clear" : "\(app.attentionCount) need you")
                    .font(.headline)
                Spacer(minLength: 8)
                SyncStatusText()
                    .font(.caption)
            }
            Picker("Show", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var content: some View {
        switch app.session {
        case .signedIn, .ssoRequired:
            if items.isEmpty {
                Text(tab == .move ? "Nothing needs you right now." : "No open PRs.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else if isPopover {
                // No scroll view here: in a menu bar window it has no natural height and collapses
                // to nothing. Ten rows at most, then a link to the main window.
                VStack(spacing: 0) {
                    rows(Array(items.prefix(limit)))
                    if items.count > limit {
                        Button("Show all \(items.count) in Docket") { show(nil) }
                            .buttonStyle(.link)
                            .padding(8)
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) { rows(items) }
                }
                .frame(maxHeight: .infinity)
            }
        case .loading:
            ProgressView().frame(maxWidth: .infinity, minHeight: 80)
        case .signedOut:
            message("Not signed in.", action: "Sign In…")
        case .needsReauth:
            message("GitHub rejected the token.", action: "Sign In Again…")
        }
    }

    @ViewBuilder private func rows(_ prs: [PRSnapshot]) -> some View {
        ForEach(prs) { pr in
            AttentionRow(pr: pr) { show(pr.id) }
                .contextMenu {
                    Button("Open on GitHub") { app.openOnGitHub(pr) }
                    Divider()
                    SnoozeMenuItems(pr: pr)
                }
            if pr.id != prs.last?.id { Divider() }
        }
    }

    private func message(_ text: String, action: String) -> some View {
        VStack(spacing: 8) {
            Text(text).foregroundStyle(.secondary)
            Button(action) { show(nil) }
        }
        .frame(maxWidth: .infinity, minHeight: 90)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Open Docket") { show(nil) }
            Spacer(minLength: 8)
            Button { app.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }
                .help("Refresh now")
                .disabled(app.isSyncing)
            Menu {
                if app.isPaused {
                    Button("Resume Notifications") { app.resume() }
                } else {
                    Button("Pause for 1 Hour") { app.pause(.oneHour) }
                    Button("Pause Until Tomorrow 9:00") { app.pause(.untilTomorrow) }
                    Button("Pause Indefinitely") { app.pause(.indefinitely) }
                }
            } label: {
                Label(app.isPaused ? "Notifications paused" : "Pause notifications", systemImage: app.isPaused ? "bell.slash" : "bell").labelStyle(.iconOnly)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help(app.isPaused ? "Notifications paused" : "Pause notifications")
            if isPopover {
                Button { openWindow(id: "compact"); dismiss() } label: { Label("Open compact window", systemImage: "rectangle.portrait.on.rectangle.portrait").labelStyle(.iconOnly) }
                    .help("Open the compact window")
            }
            SettingsLink { Label("Settings", systemImage: "gearshape").labelStyle(.iconOnly) }
                .help("Settings")
            Button { NSApp.terminate(nil) } label: { Label("Quit Docket", systemImage: "power").labelStyle(.iconOnly) }
                .help("Quit Docket")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func show(_ id: PRSnapshot.ID?) {
        if let id { app.reveal(id) }
        openWindow(id: "main")
        NSApp.activate()
        if isPopover { dismiss() }
    }
}

/// The popover gets one exact width and nothing else. The menu bar window sizes itself to the
/// content's minimum width, so any looser minimum (an earlier `minWidth: 320`) made the window
/// narrower than the content, which was then centered and clipped on both sides.
private struct SurfaceFrame: ViewModifier {
    let isPopover: Bool
    let popoverWidth: CGFloat

    func body(content: Content) -> some View {
        if isPopover {
            content.frame(width: popoverWidth)
        } else {
            content.frame(minWidth: 320, minHeight: 300, alignment: .top)
        }
    }
}

private struct AttentionRow: View {
    @Environment(AppState.self) private var app
    let pr: PRSnapshot
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Chip(state: pr.primary)
                Text("\(pr.repoName) #\(pr.number)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button { app.startClaude(pr) } label: { Label(PromptKind.forState(pr).actionTitle, systemImage: "sparkles").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Tone.accent.text)
                    .help(PromptKind.forState(pr).actionTitle)
                Button { app.openOnGitHub(pr) } label: { Label("Open on GitHub", systemImage: "arrow.up.right.square").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless)
                    .help("Open on GitHub")
            }
            Text(pr.title).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open in Docket", open)
    }
}
