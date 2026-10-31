import AppKit
import Foundation
import GitHubKit
import ReviewCore
import Sync
import UserNotifications

extension AppState {
    // MARK: Events

    /// Runs after each completed sync: diff against the baseline, suppress, plan, post.
    func processEvents(now: Date) {
        refreshSnoozes(now: now)
        defer { rebaseline() }
        guard hasSeeded else {
            // First sync after sign-in or a cleared cache: no per-PR alerts, one summary instead.
            hasSeededNow()
            let count = attentionCount
            if count > 0 && !isPaused {
                postNotifications([PlannedNotification(
                    title: "Docket is watching your pull requests",
                    subtitle: "",
                    body: "You have \(count) PR\(count == 1 ? "" : "s") that need attention.",
                    sound: nil, threadID: "summary", category: .summary, prID: nil, url: nil, kind: nil)])
            }
            return
        }
        let context = suppressionContext()
        let candidates = RulesEngine.diff(previous: baseline, current: snapshots, now: now)
            .compactMap { EventFilter.withoutBotComments($0, context: context) }
        var deliver: [PREvent] = []
        var suppressed: [Suppression: Int] = [:]
        for event in candidates {
            if let reason = EventFilter.reason(event, context: context, ledger: notificationLedger) {
                suppressed[reason, default: 0] += 1
            } else {
                deliver.append(event)
            }
        }
        if !candidates.isEmpty {
            let summary = suppressed.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: " ")
            Log.notify.notice("Events: \(candidates.count) found, \(deliver.count) delivered, suppressed: \(summary, privacy: .public)")
        }
        recordDelivered(deliver, now: now)
        postNotifications(NotificationPlanner.plan(deliver, options: notificationSettings.planOptions))
    }

    func suppressionContext() -> SuppressionContext {
        SuppressionContext(
            enabled: Set(EventKind.allCases.filter(notificationSettings.isEnabled)),
            ignoredBots: Set(notificationSettings.ignoredBots),
            snoozed: snoozed,
            mutedRepos: mutedRepos,
            paused: isPaused,
            authoredCutoff: rules.authoredCutoff)
    }

    func prepareNotifications() async {
        await notificationService.requestAuthorization()
        notificationStatus = notificationService.status
        notificationSoundsAllowed = notificationService.soundsAllowed
    }

    func refreshNotificationStatus() async {
        await notificationService.refreshStatus()
        notificationStatus = notificationService.status
        notificationSoundsAllowed = notificationService.soundsAllowed
    }

    /// Posts a fictional sample for one event type, ignoring pause and style. Settings "Test" button.
    func sendTestNotification(_ kind: EventKind) {
        let sound = notificationSettings.sound(kind)
        postNotifications([PlannedNotification(
            title: "\(kind.title) (test)", subtitle: "example-org/sample", body: "#1 Test notification from Docket",
            sound: sound.isEmpty ? nil : sound, threadID: "test", category: .pr, prID: nil, url: nil, kind: kind)])
    }

    func handleNotificationAction(_ action: String, prID: String?) {
        let pr = snapshot(id: prID)
        switch action {
        case NotificationAction.openGitHub:
            if let pr { openOnGitHub(pr) }
        case NotificationAction.openChecks:
            if let pr { openOnGitHub(pr, path: "checks") }
        case NotificationAction.snoozeHour:
            if let prID { snooze(prID, .oneHour) }
        case NotificationAction.startClaude:
            if let pr { startClaude(pr) }
        case NotificationAction.openInbox:
            browser.scope = .inbox
            openMainRequest += 1
        default:
            if let prID { reveal(prID) }
            openMainRequest += 1
        }
    }

    // MARK: Snooze

    enum SnoozeOption { case oneHour, tomorrow, untilChange }

    func snooze(_ id: PRSnapshot.ID, _ option: SnoozeOption) {
        switch option {
        case .oneHour:
            snoozes[id] = Snooze(until: Date().addingTimeInterval(3600), fingerprint: nil)
        case .tomorrow:
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
            snoozes[id] = Snooze(until: Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow), fingerprint: nil)
        case .untilChange:
            guard let pr = snapshot(id: id) else { return }
            snoozes[id] = .untilChange(pr)
        }
        saveSnoozes()
    }

    func unsnooze(_ id: PRSnapshot.ID) {
        snoozes[id] = nil
        saveSnoozes()
    }

    func refreshSnoozes(now: Date) {
        let byID = Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let active = snoozes.filter { byID[$0.key] != nil && $0.value.isActive(for: byID[$0.key], now: now) }
        if active.count != snoozes.count {
            snoozes = active
            saveSnoozes()
        }
    }

    // MARK: Repos

    func toggleMute(_ repo: String) {
        if mutedRepos.contains(repo) { mutedRepos.remove(repo) } else { mutedRepos.insert(repo) }
    }

    func applyIgnoreRules() {
        Log.app.notice("Ignore rules changed: \(self.ignoredPRPatterns.count) patterns")
        guard let engine else { return }
        let rules = IgnoreRules(ignoredPRPatterns)
        Task {
            await engine.setIgnoreRules(rules)
            publish(await engine.state, final: false)
            // Ignoring or un-ignoring is a settings change, not a PR change: do not notify about it.
            rebaseline()
            wakeRequested = true
        }
    }

    func setWatched(_ repo: String, _ watched: Bool) {
        Log.app.notice("\(watched ? "Watching" : "Stopped watching") a repo; \(self.watchedRepos.count + (watched ? 1 : -1)) watched")
        if watched { watchedRepos.insert(repo) } else { watchedRepos.remove(repo) }
        guard let engine else { return }
        let repos = watchedRepos
        Task {
            await engine.setWatchedRepos(repos)
            publish(await engine.state, final: false)
            rebaseline()
            wakeRequested = true
        }
    }

    func setHidden(_ repo: String, _ hidden: Bool) {
        Log.app.notice("\(hidden ? "Hid" : "Unhid") a repo")
        if hidden { hiddenRepos.insert(repo) } else { hiddenRepos.remove(repo) }
        if hidden, browser.scope == .repo(repo) { browser.scope = .inbox }
        applyHiddenRepos()
    }
}
