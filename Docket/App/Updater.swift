import Combine
import Foundation
import Sparkle

/// Self-update through Sparkle (docs/design/self-update.md). Only release builds made by
/// tools/release.sh have a feed URL; in any other build this stays unavailable and Sparkle never starts.
@MainActor @Observable
final class Updater {
    /// True when this build has an update feed, so the menu item and settings are shown.
    let isAvailable: Bool
    /// False while a check or an install is already in progress.
    private(set) var canCheckForUpdates = false

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: AnyCancellable?

    init(bundle: Bundle = .main) {
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        isAvailable = !feed.isEmpty && !key.isEmpty
        guard isAvailable else {
            controller = nil
            return
        }
        // Sparkle asks once, on the second launch, whether to check automatically; nothing runs in the background before that.
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
        Log.app.notice("Updates: feed \(feed, privacy: .public), automatic checks \(controller.updater.automaticallyChecksForUpdates ? "on" : "off", privacy: .public)")
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return controller?.updater.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                controller?.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }
}
