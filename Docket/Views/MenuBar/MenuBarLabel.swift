import AppKit
import SwiftUI

/// Menu bar item: template icon plus the Inbox count, with variants for paused, needs sign-in,
/// and an optional dot when CI fails on one of my PRs (off by default).
struct MenuBarLabel: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: MenuBarIcon.image(symbol: symbol, dot: app.showCIFailureDot && app.hasCIFailureOnMine))
            if app.attentionCount > 0 && !needsSignIn {
                Text("\(app.attentionCount)").monospacedDigit()
            }
        }
        .accessibilityLabel(accessibilityText)
        // Notification clicks, relaunches, and opening the app ask for the main window; this view
        // always exists, so it opens it.
        .onChange(of: app.openMainRequest) { openMain() }
        .onReceive(NotificationCenter.default.publisher(for: .docketOpenMain)) { _ in openMain() }

    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate()
    }

    private var needsSignIn: Bool {
        switch app.session {
        case .needsReauth, .ssoRequired, .signedOut: true
        default: false
        }
    }

    private var symbol: String {
        if needsSignIn { return "exclamationmark.triangle" }
        if app.isPaused { return "bell.slash" }
        return "arrow.triangle.pull"
    }

    private var accessibilityText: String {
        if needsSignIn { return "Docket, needs sign in" }
        var text = app.attentionCount == 0 ? "Docket, all clear" : "Docket, \(app.attentionCount) need you"
        if app.isPaused { text += ", notifications paused" }
        return text
    }
}

enum MenuBarIcon {
    /// A template symbol, or a non-template copy with a red dot. The dot version draws the symbol
    /// in the label color at draw time, so it still follows the menu bar's light or dark appearance.
    @MainActor
    static func image(symbol: String, dot: Bool) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
            return NSImage()
        }
        guard dot else {
            base.isTemplate = true
            return base
        }
        let size = NSSize(width: base.size.width + 3, height: base.size.height)
        let image = NSImage(size: size, flipped: false) { rect in
            let tinted = base.copy() as! NSImage
            tinted.lockFocus()
            NSColor.labelColor.set()
            NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.draw(in: NSRect(origin: .zero, size: base.size))
            NSColor(srgbRed: 1, green: 0x22 / 255, blue: 0x1E / 255, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 6, y: rect.maxY - 6, width: 6, height: 6)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
