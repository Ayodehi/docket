import AppKit
import Foundation
import GitHubKit
import Observation
import Persistence
import ReviewCore
import ServiceManagement
import Sync
import UserNotifications
import Workspace

enum Session: Equatable {
    case loading
    case signedOut
    case signedIn(login: String, scopes: [String]?)
    case needsReauth(login: String)
    case ssoRequired(login: String, url: URL?)

    var login: String? {
        switch self {
        case .signedIn(let login, _), .needsReauth(let login), .ssoRequired(let login, _): login
        case .loading, .signedOut: nil
        }
    }
}

private let syncStateFile = "sync-state.json"
private let snapshotsFile = "snapshots.json"
private let viewedFile = "viewed.json"
private let ledgerFile = "ledger.json"
private let snoozesFile = "snoozes.json"

/// Versioned so a format change re-seeds silently instead of misreading old snapshots.
private struct SnapshotFile: Codable {
    static let version = 2
    var version = SnapshotFile.version
    var snapshots: [PRSnapshot]
}

/// Main window navigation state. One source of truth for every presentation.
@MainActor @Observable
final class BrowserModel {
    var scope: Scope = .inbox
    var selection: PRSnapshot.ID?
    var searchText = ""
    var tableSort = [KeyPathComparator(\PRSnapshot.stateRank), KeyPathComparator(\PRSnapshot.updatedAt, order: .reverse)]
}

enum TableGrouping: String, Codable, CaseIterable {
    case repo, state, author, none

    var title: String {
        switch self {
        case .repo: "Repo"
        case .state: "State"
        case .author: "Author"
        case .none: "None"
        }
    }
}

/// Window and presentation preferences.
struct ViewSettings: Codable, Equatable {
    /// Presentation per scope (`Scope.storageKey`).
    var presentations: [String: Presentation] = [:]
    var defaultPresentation: Presentation = .list
    var tableGrouping: TableGrouping = .repo
    var showInspector = true
    var compactKeepOnTop = true
    var hideDockIconWhenClosed = false
    var switcherShortcut: SwitcherShortcut = .controlOptionSpace
    /// Leaves draft PRs out of the main window, menu bar, Compact window, and quick switcher.
    var hideDrafts = false

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ViewSettings()
        presentations = try c.decodeIfPresent([String: Presentation].self, forKey: .presentations) ?? d.presentations
        defaultPresentation = try c.decodeIfPresent(Presentation.self, forKey: .defaultPresentation) ?? d.defaultPresentation
        tableGrouping = try c.decodeIfPresent(TableGrouping.self, forKey: .tableGrouping) ?? d.tableGrouping
        showInspector = try c.decodeIfPresent(Bool.self, forKey: .showInspector) ?? d.showInspector
        compactKeepOnTop = try c.decodeIfPresent(Bool.self, forKey: .compactKeepOnTop) ?? d.compactKeepOnTop
        hideDockIconWhenClosed = try c.decodeIfPresent(Bool.self, forKey: .hideDockIconWhenClosed) ?? d.hideDockIconWhenClosed
        switcherShortcut = try c.decodeIfPresent(SwitcherShortcut.self, forKey: .switcherShortcut) ?? d.switcherShortcut
        hideDrafts = try c.decodeIfPresent(Bool.self, forKey: .hideDrafts) ?? d.hideDrafts
    }
}

/// Main-actor state that every scene reads.
@MainActor @Observable
final class AppState {
    var session: Session = .loading
    /// Derived status for every PR with detail loaded.
    var snapshots: [PRSnapshot] = []
    /// Tracked PRs still waiting for their first detail fetch.
    var loadingCount = 0
    /// Stack membership by PR ID, recomputed with the snapshots.
    var stacks: [String: StackPosition] = [:]
    var lastSync: Date?
    var syncError: String?
    var isSyncing = false
    var rateLimit: RateLimitInfo?
    var ssoPartial = false
    var tierCounts: [Tier: Int] = [:]
    var launchAtLogin = SMAppService.mainApp.status == .enabled
    var pollInterval: TimeInterval {
        didSet { UserDefaults.standard.set(pollInterval, forKey: "pollInterval") }
    }
    var showCIFailureDot: Bool {
        didSet { UserDefaults.standard.set(showCIFailureDot, forKey: "showCIFailureDot") }
    }
    /// Notifications are paused until this date (`distantFuture` for indefinitely).
    var pausedUntil: Date? {
        didSet { UserDefaults.standard.set(pausedUntil?.timeIntervalSince1970, forKey: "pausedUntil") }
    }
    /// Snoozed PRs and when each snooze ends.
    var snoozes: [String: Snooze] = [:]
    var snoozed: Set<String> { Set(snoozes.keys) }
    var notificationSettings: NotificationSettings {
        didSet {
            settingsStore.set(notificationSettings, forKey: "notificationSettings")
            // Ignored bots also decide which comments wait on my reply.
            if notificationSettings.ignoredBots != oldValue.ignoredBots {
                rederive()
                rebaseline()
            }
        }
    }
    var notificationStatus: UNAuthorizationStatus = .notDetermined
    var notificationSoundsAllowed = true
    /// Repos with notifications off. Their PRs still show.
    var mutedRepos: Set<String> {
        didSet { UserDefaults.standard.set(mutedRepos.sorted(), forKey: "mutedRepos") }
    }
    /// Repos removed from views and from sync.
    var hiddenRepos: Set<String> {
        didSet { UserDefaults.standard.set(hiddenRepos.sorted(), forKey: "hiddenRepos") }
    }
    /// Title patterns and `author:` rules for PRs to leave out everywhere.
    var ignoredPRPatterns: [String] {
        didSet {
            UserDefaults.standard.set(ignoredPRPatterns, forKey: "ignoredPRPatterns")
            applyIgnoreRules()
        }
    }
    var ignoredPRCount = 0
    /// Repos whose open PRs are all shown (role Watching). They never notify.
    var watchedRepos: Set<String> {
        didSet { UserDefaults.standard.set(watchedRepos.sorted(), forKey: "watchedRepos") }
    }
    /// Stacks shown as one row, by root PR ID. Shared by List, Board, and Table.
    var collapsedStacks: Set<String> {
        didSet { UserDefaults.standard.set(collapsedStacks.sorted(), forKey: "collapsedStacks") }
    }
    /// Incremented to ask a view with `openWindow` to bring up the main window.
    var openMainRequest = 0
    var viewSettings: ViewSettings {
        didSet {
            settingsStore.set(viewSettings, forKey: "viewSettings")
            if viewSettings.switcherShortcut != oldValue.switcherShortcut { GlobalHotKey.shared.register(viewSettings.switcherShortcut) }
        }
    }
    @ObservationIgnored private(set) var quickSwitcher: QuickSwitcherController?
    var workspaceSettings: WorkspaceSettings {
        didSet { settingsStore.set(workspaceSettings, forKey: "workspaceSettings") }
    }
    var tools: [Tool: URL] = [:]
    var repoIndex = LocalRepoIndex()
    var isScanningRepos = false
    var reviewWorktrees: [ReviewWorktree] = []
    /// Every linked worktree of known clones, from the last scan (Worktrees window).
    var worktreeRows: [WorktreeRow] = []
    var isScanningWorktrees = false
    var workspaceAlert: WorkspaceAlert?
    /// `<pr id>@<head sha>` of others' PRs the user agreed to run this session (AppState+Run).
    @ObservationIgnored var confirmedRunHeads: Set<String> = []
    /// Set to a repo to open Settings > Run with it selected.
    var runSettingsRepo: String?
    /// Bumped after git operations so the detail pane reloads local status.
    var localInfoVersion = 0
    /// Authored PRs not updated within this many days stay out of the Inbox. 0 means no limit.
    var inboxMaxAgeDays: Int {
        didSet { UserDefaults.standard.set(inboxMaxAgeDays, forKey: "inboxMaxAgeDays") }
    }
    /// Check name patterns left out of the CI status.
    var ignoredChecks: [String] {
        didSet {
            UserDefaults.standard.set(ignoredChecks, forKey: "ignoredChecks")
            rederive()
            // A settings change is not a PR change; do not notify about it.
            rebaseline()
        }
    }
    /// Off by default. While off, review action controls are hidden and nothing writes to GitHub
    /// (docs/design/review-actions.md).
    var reviewActionsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(reviewActionsEnabled, forKey: "reviewActionsEnabled")
            Log.github.notice("Review actions \(self.reviewActionsEnabled ? "enabled" : "disabled", privacy: .public)")
        }
    }
    let browser = BrowserModel()
    /// Main window and menu bar popover currently on screen.
    var visibleSurfaces = 0

    @ObservationIgnored private let keychain = KeychainStore(service: Bundle.main.bundleIdentifier ?? "Docket")
    @ObservationIgnored let files = try? FileStore.applicationSupport()
    @ObservationIgnored private let policy = TierPolicy()
    @ObservationIgnored private let monitor = SystemActivityMonitor()
    @ObservationIgnored private(set) var engine: SyncEngine?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored var wakeRequested = false
    @ObservationIgnored private var rateLimitedUntil: Date?
    @ObservationIgnored private var pointsThisHour = 0
    @ObservationIgnored private var usageWindowStart = Date()
    @ObservationIgnored private var syncState = SyncState()
    @ObservationIgnored private var lastViewed: [String: Date] = [:]
    @ObservationIgnored private let settingsStore = SettingsStore()
    @ObservationIgnored private let notifications = NotificationService()
    @ObservationIgnored private var ledger = NotificationLedger()
    /// Snapshots as of the last processed sync; events are transitions from these.
    @ObservationIgnored private var eventBaseline: [String: PRSnapshot] = [:]
    /// False until the first sync after sign-in or a cleared cache has been seeded silently.
    @ObservationIgnored private(set) var hasSeeded = false

    init() {
        let defaults = UserDefaults.standard
        let saved = defaults.double(forKey: "pollInterval")
        pollInterval = saved > 0 ? saved : 60
        showCIFailureDot = defaults.bool(forKey: "showCIFailureDot")
        inboxMaxAgeDays = defaults.object(forKey: "inboxMaxAgeDays") as? Int ?? 90
        ignoredChecks = defaults.stringArray(forKey: "ignoredChecks") ?? []
        let paused = defaults.double(forKey: "pausedUntil")
        pausedUntil = paused > 0 ? Date(timeIntervalSince1970: paused) : nil
        notificationSettings = SettingsStore().value(NotificationSettings.self, forKey: "notificationSettings") ?? NotificationSettings()
        mutedRepos = Set(defaults.stringArray(forKey: "mutedRepos") ?? [])
        hiddenRepos = Set(defaults.stringArray(forKey: "hiddenRepos") ?? [])
        watchedRepos = Set(defaults.stringArray(forKey: "watchedRepos") ?? [])
        collapsedStacks = Set(defaults.stringArray(forKey: "collapsedStacks") ?? [])
        ignoredPRPatterns = defaults.stringArray(forKey: "ignoredPRPatterns") ?? []
        reviewActionsEnabled = defaults.bool(forKey: "reviewActionsEnabled")
        workspaceSettings = SettingsStore().value(WorkspaceSettings.self, forKey: "workspaceSettings") ?? WorkspaceSettings()
        viewSettings = SettingsStore().value(ViewSettings.self, forKey: "viewSettings") ?? ViewSettings()
        Task { self.bootstrap() }
    }

    // MARK: Derived

    var rules: InboxRules {
        let cutoff = inboxMaxAgeDays > 0 ? Calendar.current.date(byAdding: .day, value: -inboxMaxAgeDays, to: Date()) : nil
        return InboxRules(snoozed: snoozed, authoredCutoff: cutoff, hideDrafts: viewSettings.hideDrafts)
    }

    var inbox: [PRSnapshot] {
        let rules = rules
        return snapshots.filter(rules.isInInbox).sorted(by: Browse.inboxOrder)
    }

    var attentionCount: Int { inbox.count }

    var isPaused: Bool { (pausedUntil ?? .distantPast) > Date() }

    var hasCIFailureOnMine: Bool { inbox.contains { $0.primary == .ciFailing } }

    var isStale: Bool {
        guard let lastSync else { return syncError != nil }
        return syncError != nil || Date().timeIntervalSince(lastSync) > max(3 * pollInterval, 600)
    }

    var repos: [(name: String, count: Int)] {
        let rules = rules
        return Dictionary(grouping: snapshots.filter(rules.isShown), by: \.repo).map { ($0.key, $0.value.count) }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    func snapshot(id: PRSnapshot.ID?) -> PRSnapshot? {
        guard let id else { return nil }
        return snapshots.first { $0.id == id }
    }

    func count(_ scope: Scope) -> Int {
        let rules = rules
        return snapshots.filter { Browse.inScope($0, scope, rules: rules) }.count
    }

    // MARK: Session

    private func bootstrap() {
        lastViewed = (try? files?.load([String: Date].self, from: viewedFile, decoder: GitHubJSON.decoder())) ?? [:]
        ledger = (try? files?.load(NotificationLedger.self, from: ledgerFile, decoder: GitHubJSON.decoder())) ?? NotificationLedger()
        snoozes = (try? files?.load([String: Snooze].self, from: snoozesFile, decoder: GitHubJSON.decoder())) ?? [:]
        if let file = try? files?.load(SnapshotFile.self, from: snapshotsFile, decoder: GitHubJSON.decoder()), file.version == SnapshotFile.version {
            snapshots = file.snapshots
            eventBaseline = Dictionary(file.snapshots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            hasSeeded = true
        }
        notifications.onAction = { [weak self] action, prID in self?.handleNotificationAction(action, prID: prID) }
        let cached = loadCachedState()
        publish(cached, final: false)
        if viewSettings.hideDockIconWhenClosed { NSApp.setActivationPolicy(.accessory) }
        monitor.onResume = { [weak self] in self?.wakeRequested = true }
        monitor.start()
        reconcileLaunchAtLogin()
        prepareWorkspace()
        quickSwitcher = QuickSwitcherController(app: self)
        GlobalHotKey.shared.action = { [weak self] in self?.quickSwitcher?.toggle() }
        GlobalHotKey.shared.register(viewSettings.switcherShortcut)
        do {
            if let credential = try keychain.load() {
                session = .signedIn(login: credential.account, scopes: nil)
                startSync(state: cached)
                Task { await prepareNotifications() }
            } else {
                session = .signedOut
            }
        } catch {
            session = .signedOut
            syncError = "Could not read the Keychain."
            Log.app.error("Keychain read failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Validates the token, stores it in the Keychain, and starts syncing.
    func signIn(token: String) async throws {
        let info = try await LiveGitHubClient(tokenProvider: { token }).viewer()
        var cached = loadCachedState()
        if let previous = cached.viewerLogin, previous != info.login {
            try? files?.removeAll()
            cached = SyncState()
            snapshots = []
            lastViewed = [:]
            resetNotificationState()
        }
        try keychain.save(token: token, account: info.login)
        session = .signedIn(login: info.login, scopes: info.scopes)
        syncError = nil
        Log.app.notice("Signed in as \(info.login, privacy: .private)")
        startSync(state: cached)
        await prepareNotifications()
    }

    func signOut() {
        stopSync()
        try? keychain.deleteAll()
        try? files?.removeAll()
        snapshots = []
        lastViewed = [:]
        resetNotificationState()
        publish(SyncState(), final: false)
        syncError = nil
        session = .signedOut
        Log.app.notice("Signed out")
    }

    // MARK: Sync

    func refresh() {
        guard engine != nil else {
            // After a 401 or SSO stop, Refresh retries with the stored token.
            if session.login != nil { startSync(state: loadCachedState()) }
            return
        }
        Task { await syncOnce(forceHot: true) }
    }

    /// Dock icon follows the main window when "Hide Dock icon" is on.
    func mainWindowVisibilityChanged(_ visible: Bool) {
        if visible {
            NSApp.setActivationPolicy(.regular)
        } else if viewSettings.hideDockIconWhenClosed {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Reads the token `gh` is signed in with and signs in with it. The value goes straight to the
    /// Keychain; it is never displayed or logged.
    func importTokenFromGitHubCLI() async throws {
        guard let gh = tools[.gh] else { throw WorkspaceError.toolMissing(.gh) }
        let output = try await runner.check(gh, ["auth", "token", "--hostname", "github.com"], timeout: 15)
        let token = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: \.isWhitespace) else {
            throw WorkspaceError.failed("gh did not return a token. Run gh auth login first.")
        }
        try await signIn(token: token)
    }

    /// The main window or popover appeared. Syncs soon if the data is older than the visible interval.
    func surfaceAppeared() {
        visibleSurfaces += 1
        if Date().timeIntervalSince(lastSync ?? .distantPast) > SyncSchedule.visibleInterval { wakeRequested = true }
    }

    func surfaceDisappeared() {
        visibleSurfaces = max(0, visibleSurfaces - 1)
    }

    private func startSync(state: SyncState) {
        stopSync()
        var state = state
        state.setHiddenRepos(hiddenRepos)
        state.setWatchedRepos(watchedRepos)
        state.setIgnoreRules(IgnoreRules(ignoredPRPatterns))
        let files = files
        let client = makeClient()
        engine = SyncEngine(client: client, state: state, policy: policy, progress: { [weak self] state in
            await self?.publish(state, final: false)
        }, persist: { state in
            do {
                try files?.save(state, as: syncStateFile, encoder: GitHubJSON.encoder())
            } catch {
                Log.sync.error("Saving sync state failed: \(String(describing: error), privacy: .public)")
            }
        })
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.nextDelay() != nil { await self.syncOnce(forceHot: false) }
                // While paused (asleep, locked, offline), check again every minute; resume events end the wait early.
                await self.wait(seconds: self.nextDelay() ?? 60)
            }
        }
    }

    /// A client that reads the token from the Keychain for each request.
    func makeClient() -> LiveGitHubClient {
        let keychain = keychain
        return LiveGitHubClient(tokenProvider: {
            guard let token = try keychain.load()?.token else { throw GitHubError.missingToken }
            return token
        })
    }

    /// My teams as `org/slug`, when the token can read them.
    var myTeams: Set<String> { syncState.teams ?? [] }

    private func stopSync() {
        loop?.cancel()
        loop = nil
        engine = nil
    }

    private func nextDelay() -> TimeInterval? {
        SyncSchedule.delay(conditions: monitor.conditions(windowVisible: visibleSurfaces > 0), pollInterval: pollInterval,
                           rateLimit: rateLimit, rateLimitedUntil: rateLimitedUntil, now: Date())
    }

    /// Sleeps in short ticks so wake, unlock, reconnect, and window-open requests take effect within seconds.
    private func wait(seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline && !wakeRequested && !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
        }
        wakeRequested = false
    }

    private func syncOnce(forceHot: Bool) async {
        guard let engine else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let report = try await engine.runCycle(pollInterval: pollInterval, forceHot: forceHot)
            publish(await engine.state, final: true)
            syncError = nil
            rateLimitedUntil = nil
            if case .signedIn = session {} else if let login = session.login { session = .signedIn(login: login, scopes: nil) }
            if report.searches.isEmpty && report.detailFetched == 0 {
                Log.sync.debug("Sync: nothing due")
            } else {
                Log.sync.info("Sync: \(report.searches.count) searches, \(report.detailFetched) details, \(report.pointsUsed) points")
            }
            logHourlyUsage(points: report.pointsUsed)
        } catch is CancellationError {
            return
        } catch let error as GitHubError {
            handle(error)
        } catch {
            syncError = "Sync failed. Showing the last good data."
            Log.sync.error("Sync failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// One persisted line per hour with API points used and remaining, for the PRD's API budget
    /// target (under 20 percent of the hourly limit).
    private func logHourlyUsage(points: Int) {
        pointsThisHour += points
        let now = Date()
        guard now.timeIntervalSince(usageWindowStart) >= 3600 else { return }
        let limit = rateLimit?.limit ?? 5000
        let percent = Double(pointsThisHour) / Double(limit) * 100
        Log.sync.notice("API usage: \(self.pointsThisHour) points in the last hour (\(percent, format: .fixed(precision: 1))% of \(limit)); \(self.rateLimit?.remaining ?? -1) remaining; \(self.snapshots.count) PRs tracked")
        pointsThisHour = 0
        usageWindowStart = now
    }

    private func handle(_ error: GitHubError) {
        Log.sync.error("Sync error: \(String(describing: error), privacy: .public)")
        switch error {
        case .unauthorized:
            stopSync()
            session = .needsReauth(login: session.login ?? "")
            syncError = "GitHub rejected the token. Sign in again."
        case .ssoRequired(let url):
            stopSync()
            session = .ssoRequired(login: session.login ?? "", url: url)
            syncError = "An organization requires SAML SSO authorization for this token."
        case .missingToken:
            stopSync()
            session = .signedOut
        case .rateLimited(let until):
            rateLimitedUntil = until ?? rateLimit?.resetAt ?? Date().addingTimeInterval(SyncSchedule.rateLimitSlowInterval)
            syncError = error.userMessage + " Showing the last good data."
        default:
            syncError = error.userMessage + " Showing the last good data."
        }
    }

    func publish(_ state: SyncState, final: Bool) {
        syncState = state
        lastSync = state.lastSuccess
        rateLimit = state.rateLimit
        ssoPartial = state.ssoPartial
        ignoredPRCount = state.ignoredIDs.count
        let now = Date()
        tierCounts = Dictionary(uniqueKeysWithValues: Tier.allCases.map { ($0, state.count(in: $0, now: now, policy: policy)) })
        rederive()
        if final {
            processEvents(now: now)
            try? files?.save(SnapshotFile(snapshots: snapshots), as: snapshotsFile, encoder: GitHubJSON.encoder())
            try? files?.save(lastViewed, as: viewedFile, encoder: GitHubJSON.encoder())
        }
    }

    /// Recomputes every snapshot from the current sync state, keeping `stateEnteredAt` from the previous ones.
    private func rederive() {
        guard let viewer = syncState.viewerLogin ?? session.login else { return }
        let now = Date()
        let previous = Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var derived: [PRSnapshot] = []
        var loading = 0
        for record in syncState.records.values {
            guard let pr = record.detail else { loading += 1; continue }
            if hiddenRepos.contains(pr.repository.nameWithOwner) { continue }
            // First sighting sets the "new comments" baseline, so old comments do not flood the Inbox.
            if lastViewed[pr.id] == nil { lastViewed[pr.id] = now }
            let context = DerivationContext(viewer: viewer, teams: syncState.teams, lastViewed: lastViewed, ignoredChecks: ignoredChecks,
                                            ignoredAuthors: Set(notificationSettings.ignoredBots), now: now)
            derived.append(StatusDeriver.snapshot(for: pr, context: context, foundByRequestSearch: record.sources.contains(.requested),
                                                  watched: record.sources.contains(.watched), previous: previous[pr.id]))
        }
        lastViewed = lastViewed.filter { syncState.records[$0.key] != nil }
        snapshots = derived
        stacks = Stacks.positions(derived)
        let liveStacks = collapsedStacks.filter { syncState.records[$0] != nil }
        if liveStacks != collapsedStacks { collapsedStacks = liveStacks }
        loadingCount = loading
    }

    // MARK: Notification state (used by AppState+Notifications)

    var baseline: [String: PRSnapshot] { eventBaseline }
    var notificationLedger: NotificationLedger { ledger }
    var notificationService: NotificationService { notifications }

    func hasSeededNow() {
        hasSeeded = true
    }

    /// Makes the current snapshots the baseline for the next sync's events.
    func rebaseline() {
        eventBaseline = Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Makes one PR's current snapshot its baseline, so a change I just made in Docket does not notify.
    func rebaseline(id: PRSnapshot.ID) {
        eventBaseline[id] = snapshot(id: id)
    }

    func recordDelivered(_ events: [PREvent], now: Date) {
        ledger.record(events, at: now)
        ledger.prune(now: now)
        try? files?.save(ledger, as: ledgerFile, encoder: GitHubJSON.encoder())
    }

    func postNotifications(_ planned: [PlannedNotification]) {
        notifications.post(planned)
    }

    func saveSnoozes() {
        try? files?.save(snoozes, as: snoozesFile, encoder: GitHubJSON.encoder())
    }

    func resetNotificationState() {
        eventBaseline = [:]
        hasSeeded = false
        ledger = NotificationLedger()
        snoozes = [:]
    }

    /// Pushes hidden repos to the sync engine; unhiding triggers a sync to bring their PRs back.
    func applyHiddenRepos() {
        rederive()
        rebaseline()
        guard let engine else { return }
        let hidden = hiddenRepos
        Task {
            await engine.setHiddenRepos(hidden)
            publish(await engine.state, final: false)
            wakeRequested = true
        }
    }

    private func loadCachedState() -> SyncState {
        do {
            guard let state = try files?.load(SyncState.self, from: syncStateFile, decoder: GitHubJSON.decoder()),
                  state.schemaVersion == SyncState.schemaVersion else { return SyncState() }
            return state
        } catch {
            Log.sync.error("Discarding unreadable sync cache: \(String(describing: error), privacy: .public)")
            try? files?.remove(syncStateFile)
            return SyncState()
        }
    }

    // MARK: Presentation

    static let availablePresentations: [Presentation] = [.list, .board, .table]

    var presentation: Presentation {
        get {
            let stored = viewSettings.presentations[browser.scope.storageKey] ?? viewSettings.defaultPresentation
            return Self.availablePresentations.contains(stored) ? stored : .list
        }
        set { viewSettings.presentations[browser.scope.storageKey] = newValue }
    }

    // MARK: Actions

    /// Collapses or expands the stack a PR belongs to.
    func toggleStack(of id: PRSnapshot.ID) {
        guard let root = stacks[id]?.rootID else { return }
        if collapsedStacks.contains(root) { collapsedStacks.remove(root) } else { collapsedStacks.insert(root) }
    }

    func isStackCollapsed(_ id: PRSnapshot.ID) -> Bool {
        stacks[id].map { collapsedStacks.contains($0.rootID) } ?? false
    }

    var hasStacks: Bool { !stacks.isEmpty }

    func collapseAllStacks() { collapsedStacks = Set(stacks.values.map(\.rootID)) }

    func expandAllStacks() { collapsedStacks = [] }

    /// Records that I looked at a PR, which clears "New comments".
    func markViewed(_ id: PRSnapshot.ID) {
        lastViewed[id] = Date()
        rederive()
        rebaseline()
        try? files?.save(lastViewed, as: viewedFile, encoder: GitHubJSON.encoder())
    }

    /// Shows a PR in the main window, switching to the Inbox if the current scope does not include it.
    /// Shows drafts again when the PR is a hidden draft, since the user asked for this PR.
    func reveal(_ id: PRSnapshot.ID) {
        if let pr = snapshot(id: id), !rules.isShown(pr) { viewSettings.hideDrafts = false }
        if let pr = snapshot(id: id), !Browse.inScope(pr, browser.scope, rules: rules) {
            browser.scope = rules.isInInbox(pr) ? .inbox : .repo(pr.repo)
        }
        browser.searchText = ""
        browser.selection = id
    }

    func openOnGitHub(_ pr: PRSnapshot, path: String = "") {
        let url = path.isEmpty ? pr.url : pr.url.appendingPathComponent(path)
        guard url.scheme == "https", url.host() == "github.com" else {
            Log.app.error("Refusing to open a non-GitHub PR URL")
            return
        }
        NSWorkspace.shared.open(url)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    enum PauseDuration { case oneHour, untilTomorrow, indefinitely }

    func pause(_ duration: PauseDuration) {
        switch duration {
        case .oneHour:
            pausedUntil = Date().addingTimeInterval(3600)
        case .untilTomorrow:
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
            pausedUntil = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
        case .indefinitely:
            pausedUntil = .distantFuture
        }
    }

    func resume() {
        pausedUntil = nil
    }

    // MARK: Settings

    func setLaunchAtLogin(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "launchAtLoginWanted")
        do {
            if enabled {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(Bundle.main.bundlePath, forKey: "launchAtLoginPath")
            } else {
                try SMAppService.mainApp.unregister()
                UserDefaults.standard.removeObject(forKey: "launchAtLoginPath")
            }
        } catch {
            Log.app.error("Launch at login change failed: \(String(describing: error), privacy: .public)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// The login item belongs to whichever copy of Docket registered it. When launch at login is
    /// wanted and this copy is a different one (for example the installed app replacing a
    /// development build), register this copy instead. Runs once per copy.
    func reconcileLaunchAtLogin() {
        let defaults = UserDefaults.standard
        let wanted = defaults.object(forKey: "launchAtLoginWanted") as? Bool ?? (SMAppService.mainApp.status == .enabled)
        guard wanted, defaults.string(forKey: "launchAtLoginPath") != Bundle.main.bundlePath else { return }
        try? SMAppService.mainApp.unregister()
        setLaunchAtLogin(true)
        Log.app.notice("Launch at login now opens \(Bundle.main.bundlePath, privacy: .public)")
    }
}

extension GitHubError {
    var userMessage: String {
        switch self {
        case .missingToken: "No GitHub token is stored."
        case .unauthorized: "GitHub rejected the token. It may be revoked or expired."
        case .ssoRequired: "An organization requires SAML SSO authorization for this token."
        case .rateLimited(let until):
            until.map { "GitHub rate limit reached until \($0.formatted(date: .omitted, time: .shortened))." } ?? "GitHub rate limit reached."
        case .server(let status): "GitHub returned a server error (\(status))."
        case .http(let status): "GitHub returned HTTP \(status)."
        case .graphQL(let messages): "GitHub reported an error: \(messages.first ?? "unknown")."
        case .transport: "Could not reach GitHub."
        case .decoding: "GitHub returned data Docket could not read."
        }
    }
}
