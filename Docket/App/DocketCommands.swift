import ReviewCore
import SwiftUI

/// App, View, and Go menu commands for the main window.
struct DocketCommands: Commands {
    let app: AppState
    let updater: Updater
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if updater.isAvailable {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
        CommandGroup(before: .sidebar) {
            Button("as List") { app.presentation = .list }
                .keyboardShortcut("1", modifiers: [.control, .command])
            Button("as Board") { app.presentation = .board }
                .keyboardShortcut("2", modifiers: [.control, .command])
            Button("as Table") { app.presentation = .table }
                .keyboardShortcut("3", modifiers: [.control, .command])
            Divider()
            Button(app.viewSettings.showInspector ? "Hide Inspector" : "Show Inspector") { app.viewSettings.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.option, .command])
                .disabled(app.presentation == .list)
            Button(app.viewSettings.hideDrafts ? "Show Drafts" : "Hide Drafts") { app.viewSettings.hideDrafts.toggle() }
                .keyboardShortcut("d", modifiers: [.option, .command])
            Button("Collapse All Stacks") { app.collapseAllStacks() }
                .disabled(!app.hasStacks)
            Button("Expand All Stacks") { app.expandAllStacks() }
                .disabled(app.collapsedStacks.isEmpty)
            Button("Compact Window") { openWindow(id: "compact") }
                .keyboardShortcut("m", modifiers: [.shift, .command])
            Button("Worktrees") { openWindow(id: "worktrees") }
                .keyboardShortcut("t", modifiers: [.option, .command])
            Divider()
        }
        CommandMenu("Go") {
            Button("Inbox") { show(.inbox) }.keyboardShortcut("1")
            Button("My PRs") { show(.mine) }.keyboardShortcut("2")
            Button("Reviewing") { show(.reviewing) }.keyboardShortcut("3")
            Button("Snoozed") { show(.snoozed) }.keyboardShortcut("4")
        }
    }

    private func show(_ scope: Scope) {
        app.browser.scope = scope
        openWindow(id: "main")
    }
}
