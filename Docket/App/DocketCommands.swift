import ReviewCore
import SwiftUI

/// View and Go menu commands for the main window.
struct DocketCommands: Commands {
    let app: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
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
