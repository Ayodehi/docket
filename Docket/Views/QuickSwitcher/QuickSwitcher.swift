import AppKit
import Carbon.HIToolbox
import ReviewCore
import SwiftUI
import Workspace

/// Spotlight-style panel: fuzzy search over PRs and repos. Return opens in Docket;
/// Command-Return opens on GitHub, Option-Return starts Claude, Shift-Return opens a terminal.
@MainActor
final class QuickSwitcherController {
    private let model: QuickSwitcherModel
    private var panel: SwitcherPanel?
    private var keyMonitor: Any?

    init(app: AppState) {
        model = QuickSwitcherModel(app: app)
    }

    func toggle() {
        if panel?.isVisible == true { close() } else { show() }
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        model.reset()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - frame.height * 0.22 - panel.frame.height))
        }
        panel.makeKeyAndOrderFront(nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func close() {
        panel?.orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case kVK_Escape:
            close()
        case kVK_DownArrow:
            model.move(1)
        case kVK_UpArrow:
            model.move(-1)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            let flags = event.modifierFlags
            let action: QuickSwitcherModel.Action = flags.contains(.command) ? .github : flags.contains(.option) ? .claude : flags.contains(.shift) ? .terminal : .open
            close()
            model.perform(action)
        default:
            return false
        }
        return true
    }

    private func makePanel() -> SwitcherPanel {
        let panel = SwitcherPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
                                  styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: QuickSwitcherView(model: model))
        panel.onResignKey = { [weak self] in self?.close() }
        return panel
    }
}

/// A borderless panel that can take keyboard focus without activating the app.
final class SwitcherPanel: NSPanel {
    var onResignKey: (() -> Void)?
    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

@MainActor @Observable
final class QuickSwitcherModel {
    enum Action { case open, github, claude, terminal }

    enum Item: Identifiable, Equatable {
        case pr(PRSnapshot)
        case repo(String)

        var id: String {
            switch self {
            case .pr(let pr): "pr-\(pr.id)"
            case .repo(let name): "repo-\(name)"
            }
        }
    }

    var query = "" {
        didSet { selection = 0 }
    }
    var selection = 0
    @ObservationIgnored private let app: AppState

    init(app: AppState) {
        self.app = app
    }

    func reset() {
        query = ""
        selection = 0
    }

    var prs: [PRSnapshot] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return Array(app.inbox.prefix(8)) }
        let rules = app.rules
        let shown: [PRSnapshot] = app.snapshots.filter { rules.isShown($0) }
        return shown
            .compactMap { pr in FuzzyMatch.score(query, pr: pr).map { (pr, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.updatedAt > $1.0.updatedAt }
            .prefix(8).map(\.0)
    }

    var repos: [String] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let names = Set(app.snapshots.map(\.repo)).union(app.repoIndex.clones.keys).subtracting(app.hiddenRepos)
        return names
            .compactMap { name in FuzzyMatch.score(query, in: name).map { (name, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .prefix(5).map(\.0)
    }

    var items: [Item] { prs.map(Item.pr) + repos.map(Item.repo) }

    func move(_ delta: Int) {
        let count = items.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    func perform(_ action: Action) {
        let items = items
        guard items.indices.contains(selection) else { return }
        switch items[selection] {
        case .pr(let pr):
            switch action {
            case .open:
                app.reveal(pr.id)
                app.openMainRequest += 1
            case .github: app.openOnGitHub(pr)
            case .claude: app.startClaude(pr)
            case .terminal: app.openTerminal(pr)
            }
        case .repo(let repo):
            switch action {
            case .open, .claude:
                app.browser.scope = .repo(repo)
                app.openMainRequest += 1
            case .github:
                if Safety.isSafeRepo(repo), let url = URL(string: "https://github.com/\(repo)") { NSWorkspace.shared.open(url) }
            case .terminal:
                if let clone = app.clone(for: repo) {
                    Task { try? await app.launcher.openTerminal(at: clone.path) }
                }
            }
        }
    }
}

struct QuickSwitcherView: View {
    @Bindable var model: QuickSwitcherModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Jump to a PR or repo", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        let items = model.items
                        if items.isEmpty {
                            Text(model.query.isEmpty ? "Nothing needs you." : "No matches.")
                                .foregroundStyle(.secondary)
                                .padding(14)
                        }
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index == 0, case .pr = item { header(model.query.isEmpty ? "YOUR MOVE" : "PULL REQUESTS") }
                            if case .repo = item, index == model.prs.count { header("REPOS") }
                            row(item, selected: index == model.selection)
                                .id(item.id)
                                .onTapGesture {
                                    model.selection = index
                                    model.perform(.open)
                                }
                        }
                    }
                }
                .onChange(of: model.selection) { _, index in
                    let items = model.items
                    if items.indices.contains(index) { proxy.scrollTo(items[index].id) }
                }
            }
            Divider()
            HStack(spacing: 14) {
                hint("↵", "Open")
                hint("⌘↵", "GitHub")
                hint("⌥↵", "Claude")
                hint("⇧↵", "Terminal")
                Spacer()
                hint("esc", "Close")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 620, height: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .onAppear { focused = true }
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 4)
    }

    @ViewBuilder private func row(_ item: QuickSwitcherModel.Item, selected: Bool) -> some View {
        HStack(spacing: 10) {
            switch item {
            case .pr(let pr):
                Image(systemName: pr.primary.symbol).foregroundStyle(pr.primary.tone.text).frame(width: 16)
                Text(pr.title).lineLimit(1)
                Spacer()
                Text("\(pr.repoName) #\(pr.number)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Chip(state: pr.primary)
            case .repo(let name):
                Image(systemName: "folder").foregroundStyle(.secondary).frame(width: 16)
                Text(name).lineLimit(1)
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(selected ? Tone.accent.base.opacity(0.16) : .clear)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Tone.accent.base).frame(width: 2) }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.separator))
            Text(label)
        }
    }
}
