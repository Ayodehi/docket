import AppKit
import Carbon

extension Notification.Name {
    /// Asks the menu bar label (always alive) to open the main window.
    static let docketOpenMain = Notification.Name("DocketOpenMain")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        Log.app.notice("Docket \(version, privacy: .public) launched from \(Bundle.main.bundlePath, privacy: .public)")
        // The launch Apple event is only available from here on, not in willFinishLaunching.
        let loginItem = Self.launchedAsLoginItem()
        Log.app.notice("Launch kind: \(loginItem ? "login item, menu bar only" : "opened by user, showing main window", privacy: .public)")
        if !loginItem {
            // Next run loop turn, so the menu bar label is subscribed.
            DispatchQueue.main.async { NotificationCenter.default.post(name: .docketOpenMain, object: nil) }
        }
    }

    /// Clicking the app in the Dock, Finder, or Spotlight while it runs brings up the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .docketOpenMain, object: nil)
        return true
    }

    /// Closing the main window leaves Docket in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// macOS marks the launch event of a login item with `keyAELaunchedAsLogInItem`.
    private static func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else {
            Log.app.notice("Launch event: none")
            return false
        }
        let property = event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        Log.app.notice("Launch event: class \(fourCC(event.eventClass), privacy: .public) id \(fourCC(event.eventID), privacy: .public) prop \(property.map(fourCC) ?? "none", privacy: .public)")
        return event.eventID == kAEOpenApplication && property == keyAELaunchedAsLogInItem
    }

    private static func fourCC(_ code: OSType) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .macOSRoman) ?? "\(code)"
    }
}
