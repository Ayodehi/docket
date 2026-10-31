import AppKit
import CoreGraphics
import Foundation
import IOKit.ps
import Network

/// Tracks sleep, screen lock, network, idle time, and power for `SyncSchedule`.
/// `onResume` fires on wake, unlock, and network reconnect so the app can sync right away.
@MainActor
public final class SystemActivityMonitor {
    public var onResume: (@MainActor () -> Void)?

    private var asleep = false
    private var locked = false
    private var online = true
    private let pathMonitor = NWPathMonitor()
    private var observers: [(NotificationCenter, any NSObjectProtocol)] = []

    public init() {}

    public func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.asleep = true }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.asleep = false; $0.onResume?() }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.locked = true }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.locked = false; $0.onResume?() }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let isOnline = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let reconnected = isOnline && !self.online
                self.online = isOnline
                if reconnected { self.onResume?() }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "Docket.network"))
    }

    public func conditions(windowVisible: Bool) -> SyncConditions {
        var conditions = SyncConditions()
        conditions.windowVisible = windowVisible
        conditions.asleep = asleep
        conditions.screenLocked = locked
        conditions.online = online
        conditions.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        conditions.onBatteryBelow20 = Self.onBatteryBelow20()
        // Any input event type.
        conditions.idleSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        return conditions
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (SystemActivityMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append((center, token))
    }

    static func onBatteryBelow20() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            if Double(current) / Double(max) < 0.2 { return true }
        }
        return false
    }
}
