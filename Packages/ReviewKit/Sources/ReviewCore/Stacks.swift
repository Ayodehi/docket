import Foundation

/// Where a PR sits in a stack of dependent PRs.
public struct StackPosition: Sendable, Hashable {
    /// The bottom PR of the stack (based on a branch that is not another open PR).
    public var rootID: String
    /// The PR this one is based on, if it is tracked.
    public var parentID: String?
    /// 0 for the root, 1 for a PR based on the root, and so on.
    public var depth: Int
    /// Every member, parent before children (depth-first).
    public var memberIDs: [String]
}

/// Stacked PR detection (PRD V14). A PR is based on another when, in the same repo, its base
/// branch is the other PR's head branch. Fork PRs cannot be parents: their head branch lives in
/// another repository. Uses only tracked snapshots, so a stack with an untracked middle PR splits.
public enum Stacks {
    public static func positions(_ prs: [PRSnapshot]) -> [String: StackPosition] {
        // Parent lookup: (repo, head branch) -> PR. If two open PRs share a head branch name, skip it.
        var byHead: [String: PRSnapshot] = [:]
        var duplicate = Set<String>()
        for pr in prs where !pr.isCrossRepository {
            let key = "\(pr.repo)\u{0}\(pr.headRef)"
            if byHead[key] != nil { duplicate.insert(key) }
            byHead[key] = pr
        }
        for key in duplicate { byHead[key] = nil }

        var parent: [String: String] = [:]
        var children: [String: [PRSnapshot]] = [:]
        for pr in prs {
            guard let base = byHead["\(pr.repo)\u{0}\(pr.baseRef)"], base.id != pr.id else { continue }
            parent[pr.id] = base.id
            children[base.id, default: []].append(pr)
        }

        func root(of id: String) -> String {
            var current = id
            var seen: Set<String> = [id]
            while let next = parent[current], !seen.contains(next) {
                seen.insert(next)
                current = next
            }
            return current
        }

        var result: [String: StackPosition] = [:]
        let roots = Set(parent.keys.map(root))
        for rootID in roots.sorted() {
            // Depth-first from the root; children by PR number so the order is stable.
            var members: [(String, Int)] = []
            var visited = Set<String>()
            func visit(_ id: String, _ depth: Int) {
                guard visited.insert(id).inserted else { return }
                members.append((id, depth))
                for child in (children[id] ?? []).sorted(by: { $0.number < $1.number }) { visit(child.id, depth + 1) }
            }
            visit(rootID, 0)
            let ids = members.map(\.0)
            for (id, depth) in members {
                result[id] = StackPosition(rootID: rootID, parentID: depth == 0 ? nil : parent[id], depth: depth, memberIDs: ids)
            }
        }
        return result
    }

    /// Reorders a list so members of each stack that appear in it are contiguous, parent first,
    /// at the position of the stack's first member. Everything else keeps its order.
    public static func grouped(_ prs: [PRSnapshot], positions: [String: StackPosition]) -> [PRSnapshot] {
        guard !positions.isEmpty else { return prs }
        let present = Dictionary(prs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var placed = Set<String>()
        var result: [PRSnapshot] = []
        for pr in prs where !placed.contains(pr.id) {
            guard let position = positions[pr.id] else {
                result.append(pr)
                placed.insert(pr.id)
                continue
            }
            for id in position.memberIDs where !placed.contains(id) {
                if let member = present[id] {
                    result.append(member)
                    placed.insert(id)
                }
            }
        }
        return result
    }
}

/// A list with stacks kept together and collapsed stacks folded into their first row.
public struct StackFold: Sendable {
    /// Rows to show, in order.
    public var items: [PRSnapshot]
    /// For the first row of each stack run with more than one member: the other members of that
    /// run, parent first, whether they are folded or shown.
    public var followers: [String: [PRSnapshot]]
    /// First rows whose followers are folded away (not in `items`).
    public var collapsedHeads: Set<String>

    /// Every PR in the list, folded or not.
    public var count: Int { items.count + collapsedHeads.reduce(0) { $0 + (followers[$1]?.count ?? 0) } }
}

extension Stacks {
    /// Groups stacks like `grouped(_:positions:)`, then folds each run of a collapsed stack into
    /// the run's first row. `collapsed` holds stack root IDs. A run is the stack members present in
    /// this list, so a stack split across sections folds separately in each one, and nothing moves
    /// out of its section.
    public static func fold(_ prs: [PRSnapshot], positions: [String: StackPosition], collapsed: Set<String>) -> StackFold {
        var result = StackFold(items: [], followers: [:], collapsedHeads: [])
        var head: (id: String, root: String)?
        for pr in grouped(prs, positions: positions) {
            if let root = positions[pr.id]?.rootID, let current = head, current.root == root {
                result.followers[current.id, default: []].append(pr)
                if collapsed.contains(root) {
                    result.collapsedHeads.insert(current.id)
                    continue
                }
            } else {
                head = positions[pr.id].map { (pr.id, $0.rootID) }
            }
            result.items.append(pr)
        }
        return result
    }
}
