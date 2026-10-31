import SwiftUI

/// The popover's list in its own window, optionally floating above other apps' windows.
struct CompactWindowView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        AttentionListView(isPopover: false)
            .toolbar {
                ToolbarItem {
                    Toggle(isOn: Binding(get: { app.viewSettings.compactKeepOnTop }, set: { app.viewSettings.compactKeepOnTop = $0 })) {
                        Label("Keep on Top", systemImage: app.viewSettings.compactKeepOnTop ? "pin.fill" : "pin")
                    }
                    .help("Keep this window above other windows")
                }
                ToolbarItem {
                    Button {
                        openWindow(id: "main")
                        NSApp.activate()
                    } label: {
                        Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .help("Open the main window")
                }
            }
            .navigationTitle("Your move · \(app.attentionCount)")
            .configureWindow { window in
                let level: NSWindow.Level = app.viewSettings.compactKeepOnTop ? .floating : .normal
                if window.level != level { window.level = level }
            }
    }
}
