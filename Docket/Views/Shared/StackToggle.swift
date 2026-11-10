import ReviewCore
import SwiftUI

/// Disclosure on the first row of a stack run. Collapsed, it also says how many PRs are folded in.
struct StackToggle: View {
    @Environment(\.appState) private var app
    let pr: PRSnapshot
    /// The other members of this run.
    let followers: [PRSnapshot]

    var body: some View {
        let collapsed = app.isStackCollapsed(pr.id)
        Button { app.toggleStack(of: pr.id) } label: {
            HStack(spacing: 3) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .imageScale(.small)
                    .frame(width: 10)
                if collapsed {
                    Label("+\(followers.count) stacked", systemImage: "square.stack.3d.up")
                        .font(.caption).lineLimit(1)
                }
            }
            .foregroundStyle(Tone.accent.text)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Show the \(followers.count) PRs stacked on #\(pr.number)" : "Collapse this stack into one row")
        .accessibilityLabel(collapsed ? "Expand stack, \(followers.count) more" : "Collapse stack")
    }
}

/// Context menu item for the stack a PR belongs to.
struct StackMenuItem: View {
    @Environment(\.appState) private var app
    let pr: PRSnapshot

    var body: some View {
        if let stack = app.stacks[pr.id], stack.memberIDs.count > 1 {
            Button(app.isStackCollapsed(pr.id) ? "Expand Stack" : "Collapse Stack") { app.toggleStack(of: pr.id) }
        }
    }
}
