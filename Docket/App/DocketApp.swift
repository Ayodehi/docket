import SwiftUI

@main
struct DocketApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState.shared
    @State private var updater = Updater()

    var body: some Scene {
        MenuBarExtra {
            AttentionListView()
                .environment(\.appState, appState)
        } label: {
            MenuBarLabel()
                .environment(\.appState, appState)
        }
        .menuBarExtraStyle(.window)

        Window("Docket", id: "main") {
            MainView()
                .environment(\.appState, appState)
        }
        .defaultSize(width: 1100, height: 700)
        .commands { DocketCommands(app: appState, updater: updater) }

        Window("Compact", id: "compact") {
            CompactWindowView()
                .environment(\.appState, appState)
        }
        .defaultSize(width: 400, height: 600)

        Window("Worktrees", id: "worktrees") {
            WorktreesView()
                .environment(\.appState, appState)
        }
        .defaultSize(width: 1000, height: 520)

        Settings {
            SettingsView()
                .environment(\.appState, appState)
                .environment(updater)
        }
    }
}
