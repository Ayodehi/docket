import AppKit
import ReviewCore
import SwiftUI

/// Status tones. Text colors have separate light and dark values for contrast.
enum Tone {
    case accent, sky, ok, warn, err, off

    var base: Color {
        switch self {
        case .accent: Color(hex: 0x38C0C7)
        case .sky: Color(hex: 0x33B7F4)
        case .ok: Color(hex: 0x00A04D)
        case .warn: Color(hex: 0xFE9500)
        case .err: Color(hex: 0xFF221E)
        case .off: Color(hex: 0x5B5D5F)
        }
    }

    var text: Color {
        switch self {
        case .accent: .dynamic(light: 0x137F85, dark: 0x38C0C7)
        case .sky: .dynamic(light: 0x0B6E9C, dark: 0x33B7F4)
        case .ok: .dynamic(light: 0x00793A, dark: 0x2FC06F)
        case .warn: .dynamic(light: 0xA85F00, dark: 0xFFAB33)
        case .err: .dynamic(light: 0xC8120E, dark: 0xFF5A56)
        case .off: .secondary
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

extension PrimaryState {
    var tone: Tone {
        switch self {
        case .reviewRequested, .reReviewRequested: .accent
        case .changesRequested, .conflicts, .behindBase: .warn
        case .ciFailing: .err
        case .readyToMerge: .ok
        case .newComments, .ciRunning: .sky
        case .draft, .waitingForReview, .pendingRemediation, .reviewed, .watching, .open: .off
        }
    }

    var symbol: String {
        switch self {
        case .reviewRequested, .reReviewRequested, .watching: "eye"
        case .changesRequested, .pendingRemediation: "pencil"
        case .ciFailing: "xmark"
        case .conflicts: "exclamationmark.triangle"
        case .readyToMerge: "arrow.triangle.merge"
        case .newComments: "text.bubble"
        case .behindBase: "arrow.down.to.line"
        case .draft: "circle.dashed"
        case .waitingForReview: "clock"
        case .ciRunning: "arrow.clockwise"
        case .reviewed: "checkmark"
        case .open: "circle"
        }
    }
}

extension CIStatus {
    var tone: Tone {
        switch self {
        case .passing: .ok
        case .failing: .err
        case .running: .sky
        case .none: .off
        }
    }

    var symbol: String {
        switch self {
        case .passing: "checkmark"
        case .failing: "xmark"
        case .running: "arrow.clockwise"
        case .none: "minus"
        }
    }

    var title: String {
        switch self {
        case .passing: "Passing"
        case .failing: "Failing"
        case .running: "Running"
        case .none: "No checks"
        }
    }
}

extension CheckState {
    var tone: Tone {
        switch self {
        case .passing: .ok
        case .failing: .err
        case .running: .sky
        case .neutral: .off
        }
    }

    var symbol: String {
        switch self {
        case .passing: "checkmark"
        case .failing: "xmark"
        case .running: "arrow.clockwise"
        case .neutral: "minus"
        }
    }
}

extension MergeReadiness {
    var title: String {
        switch self {
        case .conflicts: "Conflicts"
        case .behind: "Behind base"
        case .blocked: "Blocked"
        case .ready: "Mergeable"
        case .draft: "Draft"
        case .unknown: "Checking mergeability"
        }
    }

    var tone: Tone {
        switch self {
        case .conflicts, .behind: .warn
        case .ready: .ok
        case .blocked, .draft, .unknown: .off
        }
    }
}

extension ReviewerVerdict {
    var title: String {
        switch self {
        case .requested: "requested"
        case .approved: "approved"
        case .changesRequested: "changes requested"
        case .commented: "commented"
        case .dismissed: "dismissed"
        }
    }

    var tone: Tone {
        switch self {
        case .requested: .accent
        case .approved: .ok
        case .changesRequested: .warn
        case .commented, .dismissed: .off
        }
    }

    var symbol: String {
        switch self {
        case .requested: "eye"
        case .approved: "checkmark"
        case .changesRequested: "pencil"
        case .commented: "text.bubble"
        case .dismissed: "minus"
        }
    }
}

/// Status chip: icon plus text, never color alone.
struct Chip: View {
    let text: String
    let symbol: String
    let tone: Tone

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).imageScale(.small)
            Text(text)
        }
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .foregroundStyle(tone.text)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(tone.base.opacity(0.13), in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tone.base.opacity(0.3)))
        .fixedSize()
    }
}

extension Chip {
    init(state: PrimaryState) {
        self.init(text: state.title, symbol: state.symbol, tone: state.tone)
    }

    init(ci: CIStatus, short: Bool = true) {
        self.init(text: short ? "CI" : "CI \(ci.title.lowercased())", symbol: ci.symbol, tone: ci.tone)
    }
}

enum Age {
    /// Compact age like the mockups: 14m, 3h, 2d.
    static func short(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 3600 { return "\(max(1, Int(seconds / 60)))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}

extension ReviewStatus {
    var title: String {
        switch self {
        case .changesRequested: "Changes requested"
        case .approved: "Approved"
        case .reviewRequired: "Review required"
        case .commented: "Commented"
        case .noReviews: "No reviews"
        }
    }
}

/// Comparable keys for Table sorting.
extension PRSnapshot {
    /// Your-move states first, then by urgency order in the status model.
    var stateRank: Int { (primary.isMyMove ? 0 : 100) + primary.rawValue }
    var ciRank: Int {
        switch ci {
        case .failing: 0
        case .running: 1
        case .passing: 2
        case .none: 3
        }
    }
    var reviewRank: Int {
        switch review {
        case .changesRequested: 0
        case .reviewRequired: 1
        case .commented: 2
        case .noReviews: 3
        case .approved: 4
        }
    }
    var mergeRank: Int {
        switch merge {
        case .conflicts: 0
        case .behind: 1
        case .blocked: 2
        case .unknown: 3
        case .draft: 4
        case .ready: 5
        }
    }
}

/// Indent level for a PR's depth in a stack. Each level is one step deeper so parent and child
/// never line up; past the cap, the "on #N" marker still names the parent.
enum StackIndent {
    static let maxLevel = 8
    static func level(_ depth: Int) -> Int { min(max(depth, 0), maxLevel) }
}
