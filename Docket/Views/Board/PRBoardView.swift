import ReviewCore
import SwiftUI

/// Columns per state group. Arrow keys move the selection between cards and columns.
struct PRBoardView: View {
    @Environment(\.appState) private var app
    @FocusState private var focused: Bool

    static let minimumWidth: CGFloat = 420
    private static let columnWidth: CGFloat = 260

    var body: some View {
        let visible = Browse.visible(app.snapshots, scope: app.browser.scope, text: app.browser.searchText, rules: app.rules)
        let folds = Browse.boardColumns(visible).map { column in
            (column, Stacks.fold(column.items, positions: app.stacks, collapsed: app.collapsedStacks))
        }
        // Columns hold the cards shown, so arrow keys skip folded PRs.
        let columns = folds.map { PRSection(id: $0.0.id, title: $0.0.title, items: $0.1.items) }
        let followers = folds.reduce(into: [String: [PRSnapshot]]()) { $0.merge($1.1.followers) { first, _ in first } }
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(columns) { column in
                        BoardColumn(column: column, total: folds.first { $0.0.id == column.id }?.1.count ?? column.items.count,
                                    followers: followers, tone: Self.tone(column.id))
                            .frame(width: Self.columnWidth)
                    }
                }
                .padding(14)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
                guard let id = Self.move(from: app.browser.selection, key: press.key, columns: columns) else { return .ignored }
                app.browser.selection = id
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                return .handled
            }
            .onTapGesture { focused = true }
        }
        .accessibilityLabel("Board")
    }

    static func tone(_ column: String) -> Tone {
        switch column {
        case "requested": .accent
        case "feedback", "conflicts": .warn
        case "ci": .err
        case "ready": .ok
        default: .off
        }
    }

    static func move(from selection: PRSnapshot.ID?, key: KeyEquivalent, columns: [PRSection]) -> PRSnapshot.ID? {
        let move: Browse.BoardMove
        switch key {
        case .upArrow: move = .up
        case .downArrow: move = .down
        case .leftArrow: move = .left
        case .rightArrow: move = .right
        default: return nil
        }
        return Browse.boardMove(from: selection, move, columns: columns)
    }
}

private struct BoardColumn: View {
    @Environment(\.appState) private var app
    let column: PRSection
    /// PRs in the column, counting those folded into a collapsed stack.
    let total: Int
    let followers: [String: [PRSnapshot]]
    let tone: Tone

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5).fill(tone.base).frame(width: 3, height: 12)
                Text(column.title).font(.callout.weight(.semibold))
                Spacer()
                Text("\(total)").font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
            ScrollView {
                LazyVStack(spacing: 8) {
                    if column.items.isEmpty {
                        Text("Nothing here").font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    }
                    ForEach(column.items) { pr in
                        BoardCard(pr: pr, selected: app.browser.selection == pr.id, showsState: column.id == "waiting",
                                  followers: followers[pr.id] ?? [])
                            .id(pr.id)
                            .onTapGesture { app.browser.selection = pr.id }
                            .contextMenu { RowMenu(pr: pr) }
                    }
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
        .opacity(column.id == "waiting" ? 0.85 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(column.title), \(total)")
    }
}

private struct BoardCard: View {
    @Environment(\.appState) private var app
    let pr: PRSnapshot
    let selected: Bool
    let showsState: Bool
    var followers: [PRSnapshot] = []

    var body: some View {
        let stack = app.stacks[pr.id]
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                if !followers.isEmpty { StackToggle(pr: pr, followers: followers) }
                if let stack, let parent = stack.parentID.flatMap(app.snapshot(id:)) {
                    Image(systemName: "arrow.turn.down.right").imageScale(.small).foregroundStyle(Tone.accent.text)
                        .help("Based on #\(parent.number)")
                }
                Text("\(pr.repoName) #\(pr.number) · \(pr.isMine ? "yours" : pr.author) · \(Age.short(since: pr.stateEnteredAt))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(pr.title).font(.callout.weight(.medium)).lineLimit(2)
            HStack(spacing: 5) {
                Chip(ci: pr.ci)
                if showsState { Chip(state: pr.primary) }
                if pr.unresolvedThreads > 0 { Chip(text: "\(pr.unresolvedThreads)", symbol: "text.bubble", tone: .warn) }
                if let stack, stack.memberIDs.count > 1 {
                    Chip(text: "Stack \(stack.memberIDs.firstIndex(of: pr.id).map { $0 + 1 } ?? 1)/\(stack.memberIDs.count)",
                         symbol: "square.stack.3d.up", tone: .accent)
                }
                if app.snoozed.contains(pr.id) { Image(systemName: "moon.fill").foregroundStyle(.secondary).accessibilityLabel("Snoozed") }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, CGFloat(StackIndent.level(stack?.depth ?? 0)) * 6)
        .background(selected ? Tone.accent.base.opacity(0.14) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Tone.accent.base : Color(nsColor: .separatorColor), lineWidth: selected ? 1.5 : 1))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
