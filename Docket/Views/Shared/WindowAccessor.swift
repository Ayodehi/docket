import AppKit
import SwiftUI

/// Hands the hosting `NSWindow` to `configure` for settings SwiftUI does not expose (full screen
/// behavior, window level). SwiftUI can reset some window properties on later updates (for example
/// when the title changes), so `configure` runs again on every view update and whenever the window
/// becomes key. `configure` must be idempotent.
struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowTrackingView {
        let view = WindowTrackingView()
        view.configure = configure
        return view
    }

    func updateNSView(_ view: WindowTrackingView, context: Context) {
        view.configure = configure
        if let window = view.window { configure(window) }
    }

    final class WindowTrackingView: NSView {
        var configure: ((NSWindow) -> Void)?
        private var observer: (any NSObjectProtocol)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Leaving the window (nil) removes the observer; the closure only holds self weakly.
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            configure?(window)
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window else { return }
                    self.configure?(window)
                }
            }
        }
    }
}

extension View {
    func configureWindow(_ configure: @escaping (NSWindow) -> Void) -> some View {
        background(WindowAccessor(configure: configure))
    }

    /// Lets the green window button and Control-Command-F enter real full screen instead of zooming.
    ///
    /// SwiftUI marks this window `.auxiliary` and `.fullScreenAuxiliary` (the app's first scene is the
    /// menu bar extra) and re-applies that on its own schedule, including after entering full screen.
    /// So the window's `collectionBehavior` is observed and corrected whenever it changes.
    func allowsFullScreen() -> some View {
        configureWindow { FullScreenGuard.install(on: $0) }
    }
}

/// Keeps a window full-screen capable by correcting `collectionBehavior` whenever it changes.
@MainActor
enum FullScreenGuard {
    private static var observations: [ObjectIdentifier: NSKeyValueObservation] = [:]

    static func install(on window: NSWindow) {
        correct(window)
        let id = ObjectIdentifier(window)
        guard observations[id] == nil else { return }
        observations[id] = window.observe(\.collectionBehavior, options: [.new]) { window, _ in
            // KVO can arrive off the main thread in principle; hop to be safe.
            DispatchQueue.main.async { MainActor.assumeIsolated { correct(window) } }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { observations[id] = nil }
        }
    }

    private static func correct(_ window: NSWindow) {
        let wanted = window.collectionBehavior.subtracting([.fullScreenAuxiliary, .fullScreenNone, .auxiliary]).union([.fullScreenPrimary, .managed])
        guard window.collectionBehavior != wanted else { return }
        window.collectionBehavior = wanted
    }
}
