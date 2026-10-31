import Foundation
import os

/// Unified logging categories. Interpolate user and PR identifiers with `privacy: .private`;
/// never log tokens or response bodies.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "Docket"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let github = Logger(subsystem: subsystem, category: "github")
    static let notify = Logger(subsystem: subsystem, category: "notify")
    static let workspace = Logger(subsystem: subsystem, category: "workspace")
}
