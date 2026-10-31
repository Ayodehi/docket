import SwiftUI

@main
struct DocketApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            AttentionListView()
                .environment(appState)
        } label: {
            MenuBarLabel()
                .environment(appState)
        }
        .menuBarExtraStyle(.window)

        Window("Docket", id: "main") {
            MainView()
                .environment(appState)
        }
        .defaultSize(width: 1100, height: 700)
        .commands { DocketCommands(app: appState) }

        Window("Compact", id: "compact") {
            CompactWindowView()
                .environment(appState)
        }
        .defaultSize(width: 400, height: 600)

        Window("Worktrees", id: "worktrees") {
            WorktreesView()
                .environment(appState)
        }
        .defaultSize(width: 1000, height: 520)

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}
