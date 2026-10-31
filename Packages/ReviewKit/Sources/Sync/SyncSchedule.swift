import Foundation
import GitHubKit

/// What the machine is doing, as far as polling cares.
public struct SyncConditions: Sendable, Equatable {
    public var windowVisible = false
    public var idleSeconds: TimeInterval = 0
    public var lowPowerMode = false
    public var onBatteryBelow20 = false
    public var asleep = false
    public var screenLocked = false
    public var online = true

    public init() {}
}

/// Adaptive polling from docs/github-integration.md section 3.
public enum SyncSchedule {
    public static let visibleInterval: TimeInterval = 30
    public static let idleThreshold: TimeInterval = 10 * 60
    public static let slowInterval: TimeInterval = 5 * 60
    public static let rateLimitSlowInterval: TimeInterval = 10 * 60

    /// Seconds until the next sync, or `nil` while syncing should pause (asleep, locked, offline).
    public static func delay(conditions: SyncConditions, pollInterval: TimeInterval, rateLimit: RateLimitInfo?, rateLimitedUntil: Date?, now: Date) -> TimeInterval? {
        if conditions.asleep || conditions.screenLocked || !conditions.online { return nil }
        var delay = conditions.windowVisible ? min(visibleInterval, pollInterval) : pollInterval
        if conditions.idleSeconds > idleThreshold || conditions.lowPowerMode || conditions.onBatteryBelow20 {
            delay = max(delay, slowInterval)
        }
        if let rate = rateLimit, let limit = rate.limit, limit > 0, rate.resetAt > now, Double(rate.remaining) < Double(limit) * 0.1 {
            delay = max(delay, min(rateLimitSlowInterval, rate.resetAt.timeIntervalSince(now)))
        }
        if let until = rateLimitedUntil, until > now {
            delay = max(delay, until.timeIntervalSince(now))
        }
        return delay
    }
}
