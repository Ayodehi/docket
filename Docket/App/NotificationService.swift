import AppKit
import ReviewCore
import UserNotifications
import Workspace

/// Notification settings (Settings > Notifications). Missing per-kind values use the defaults in `EventKind`.
struct NotificationSettings: Codable, Equatable {
    static let soundNames = ["Request", "Attention", "Failure", "Success", "Soft"]

    var style: NotificationStyle = .smart
    var enabled: [EventKind: Bool] = [:]
    var sounds: [EventKind: String] = [:]
    var highUrgency: [EventKind: Bool] = [:]
    var hideTitles = false
    var ignoredBots = ["dependabot[bot]", "renovate[bot]", "github-actions[bot]"]

    func isEnabled(_ kind: EventKind) -> Bool { enabled[kind] ?? kind.enabledByDefault }
    func isHighUrgency(_ kind: EventKind) -> Bool { highUrgency[kind] ?? kind.highUrgencyByDefault }
    /// A bundled sound name, "default" for the system sound, or "" for none.
    func sound(_ kind: EventKind) -> String { sounds[kind] ?? kind.defaultSound }

    var planOptions: NotificationPlanOptions {
        NotificationPlanOptions(
            style: style,
            highUrgency: Set(EventKind.allCases.filter(isHighUrgency)),
            sounds: Dictionary(uniqueKeysWithValues: EventKind.allCases.map { ($0, sound($0)) }),
            hideTitles: hideTitles)
    }
}

enum NotificationAction {
    static let openGitHub = "OPEN_GITHUB"
    static let openChecks = "OPEN_CHECKS"
    static let openApp = "OPEN_APP"
    static let openInbox = "OPEN_INBOX"
    static let snoozeHour = "SNOOZE_1H"
    static let startClaude = "START_CLAUDE"
}

/// Posts system notifications and routes their actions back to `AppState`.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    var onAction: ((_ action: String, _ prID: String?) -> Void)?
    private(set) var status: UNAuthorizationStatus = .notDetermined
    /// Whether macOS lets Docket's notifications play sounds (System Settings > Notifications > Docket).
    private(set) var soundsAllowed = true

    override init() {
        super.init()
        center.delegate = self
        registerCategories()
        Self.installSounds()
    }

    /// Notification Center on macOS 27 resolves custom sounds only from the system sound libraries,
    /// not the app bundle (it logged "Tone ... is neither in ... system or iTunes tones" and fell
    /// back to the default chime). So the bundled tones are copied to ~/Library/Sounds with a
    /// Docket- prefix, refreshed whenever the bundled file differs.
    static func installSounds() {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Sounds", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for name in NotificationSettings.soundNames {
                guard let source = Bundle.main.url(forResource: name, withExtension: "caf") else { continue }
                let target = dir.appendingPathComponent(soundFileName(name))
                let bundled = try Data(contentsOf: source)
                if (try? Data(contentsOf: target)) == bundled { continue }
                try bundled.write(to: target, options: .atomic)
                Log.notify.notice("Installed sound \(target.lastPathComponent, privacy: .public)")
            }
        } catch {
            Log.notify.error("Installing notification sounds failed: \(String(describing: error), privacy: .public)")
        }
    }

    static func soundFileName(_ name: String) -> String { "Docket-\(name).caf" }

    func requestAuthorization() async {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            Log.notify.error("Notification authorization failed: \(String(describing: error), privacy: .public)")
        }
        await refreshStatus()
    }

    func refreshStatus() async {
        let settings = await center.notificationSettings()
        status = settings.authorizationStatus
        soundsAllowed = settings.soundSetting != .disabled
        Log.notify.notice("Notification settings: authorization \(settings.authorizationStatus.rawValue, privacy: .public), sound \(settings.soundSetting.rawValue, privacy: .public), alert style \(settings.alertStyle.rawValue, privacy: .public)")
    }

    func post(_ notifications: [PlannedNotification]) {
        for planned in notifications {
            let content = UNMutableNotificationContent()
            content.title = planned.title
            content.subtitle = planned.subtitle
            content.body = planned.body
            content.threadIdentifier = planned.threadID
            content.categoryIdentifier = Self.categoryID(for: planned)
            var info: [String: String] = [:]
            if let id = planned.prID { info["prID"] = id }
            content.userInfo = info
            switch planned.sound {
            case nil: content.sound = nil
            case "default": content.sound = .default
            case let name?: content.sound = UNNotificationSound(named: UNNotificationSoundName(Self.soundFileName(name)))
            }
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request) { error in
                if let error { Log.notify.error("Posting failed: \(String(describing: error), privacy: .public)") }
            }
        }
        if !notifications.isEmpty { Log.notify.notice("Posted \(notifications.count) notifications") }
    }

    /// PR notifications whose event has a matching Claude prompt get a category with that action.
    static func categoryID(for planned: PlannedNotification) -> String {
        guard planned.prID != nil, let kind = planned.kind else { return planned.category.rawValue }
        switch kind {
        case .reviewRequested, .reReviewRequested: return "CLAUDE_\(PromptKind.review.rawValue)"
        case .changesRequested, .newComment: return "CLAUDE_\(PromptKind.addressFeedback.rawValue)"
        case .ciFailed: return "CLAUDE_\(PromptKind.fixCI.rawValue)"
        case .conflicts: return "CLAUDE_\(PromptKind.resolveConflicts.rawValue)"
        default: return planned.category.rawValue
        }
    }

    private func registerCategories() {
        let github = UNNotificationAction(identifier: NotificationAction.openGitHub, title: "Open on GitHub")
        let checks = UNNotificationAction(identifier: NotificationAction.openChecks, title: "Open Checks")
        let app = UNNotificationAction(identifier: NotificationAction.openApp, title: "Open in Docket", options: [.foreground])
        let inbox = UNNotificationAction(identifier: NotificationAction.openInbox, title: "Open Inbox", options: [.foreground])
        let snooze = UNNotificationAction(identifier: NotificationAction.snoozeHour, title: "Snooze 1 Hour")
        let claudeCategories = PromptKind.allCases.map { kind in
            let claude = UNNotificationAction(identifier: NotificationAction.startClaude, title: kind.actionTitle)
            let second = kind == .fixCI ? checks : github
            return UNNotificationCategory(identifier: "CLAUDE_\(kind.rawValue)", actions: [claude, second, snooze], intentIdentifiers: [])
        }
        center.setNotificationCategories(Set(claudeCategories).union([
            UNNotificationCategory(identifier: PlannedNotification.Category.pr.rawValue, actions: [github, app, snooze], intentIdentifiers: []),
            UNNotificationCategory(identifier: PlannedNotification.Category.ci.rawValue, actions: [checks, app, snooze], intentIdentifiers: []),
            UNNotificationCategory(identifier: PlannedNotification.Category.summary.rawValue, actions: [inbox], intentIdentifiers: []),
        ]))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let prID = response.notification.request.content.userInfo["prID"] as? String
        let category = response.notification.request.content.categoryIdentifier
        await MainActor.run {
            // A plain click opens the PR in Docket, or the Inbox for a summary.
            let resolved = action == UNNotificationDefaultActionIdentifier
                ? (category == PlannedNotification.Category.summary.rawValue ? NotificationAction.openInbox : NotificationAction.openApp)
                : action
            onAction?(resolved, prID)
        }
    }
}
