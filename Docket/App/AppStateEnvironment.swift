import SwiftUI

extension AppState {
    /// The app's only `AppState`. `DocketApp` puts it in each scene's environment, and views read it
    /// with `@Environment(\.appState)`.
    static let shared = AppState()
}

/// `AppState` as a keyed environment value whose default is `AppState.shared`.
///
/// Looking it up by type (`@Environment(AppState.self)`) is a fatal error when the object is
/// missing. On macOS 27, SwiftUI sometimes evaluates views in separately hosted pieces of a window
/// (toolbar items next to a toolbar search field, table cells during a scroll) without the window's
/// environment, which crashed Docket twice on 2026-11-09. A keyed value falls back to the same
/// shared object instead, so those views keep working. Observation is unchanged: views still track
/// the properties they read.
private struct AppStateKey: EnvironmentKey {
    static var defaultValue: AppState {
        MainActor.assumeIsolated { AppState.shared }
    }
}

extension EnvironmentValues {
    var appState: AppState {
        get { self[AppStateKey.self] }
        set { self[AppStateKey.self] = newValue }
    }
}
