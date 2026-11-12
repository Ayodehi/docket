import Foundation

/// Marking a PR as under my review when a review session starts, and clearing the label once
/// the review is posted (docs/design/review-claim.md). Build actions with the `make` functions,
/// which validate every identifier before any request is made.
public enum ClaimAction: Sendable, Hashable {
    /// Adds a user (node ID) to the PR's assignees. Existing assignees are kept.
    case assign(pullRequestID: String, userID: String)
    /// Adds a label (node ID) to the PR. Existing labels are kept.
    case addLabel(pullRequestID: String, labelID: String)
    /// Removes one label (node ID) from the PR.
    case removeLabel(pullRequestID: String, labelID: String)

    public static func makeAssign(pullRequestID: String, userID: String) throws -> ClaimAction {
        try ReviewInput.checkNodeID(pullRequestID)
        try ReviewInput.checkNodeID(userID)
        return .assign(pullRequestID: pullRequestID, userID: userID)
    }

    public static func makeAddLabel(pullRequestID: String, labelID: String) throws -> ClaimAction {
        try ReviewInput.checkNodeID(pullRequestID)
        try ReviewInput.checkNodeID(labelID)
        return .addLabel(pullRequestID: pullRequestID, labelID: labelID)
    }

    public static func makeRemoveLabel(pullRequestID: String, labelID: String) throws -> ClaimAction {
        try ReviewInput.checkNodeID(pullRequestID)
        try ReviewInput.checkNodeID(labelID)
        return .removeLabel(pullRequestID: pullRequestID, labelID: labelID)
    }

    /// Short name for logs.
    public var name: String {
        switch self {
        case .assign: "assign"
        case .addLabel: "add label"
        case .removeLabel: "remove label"
        }
    }

    var query: String {
        switch self {
        case .assign: Queries.addAssignee
        case .addLabel: Queries.addLabel
        case .removeLabel: Queries.removeLabel
        }
    }

    var variables: [String: Any] {
        switch self {
        case .assign(let pr, let user): ["pr": pr, "ids": [user]]
        case .addLabel(let pr, let label), .removeLabel(let pr, let label): ["pr": pr, "ids": [label]]
        }
    }
}

/// What a claim needs from GitHub before it can write: my node ID, and the label's node ID in the
/// PR's repository (`nil` when the repository has no label with that name).
public struct ClaimTargets: Sendable, Hashable {
    public var viewerID: String
    public var labelID: String?
    /// The label's name as the repository spells it.
    public var labelName: String?

    public init(viewerID: String, labelID: String?, labelName: String?) {
        self.viewerID = viewerID
        self.labelID = labelID
        self.labelName = labelName
    }
}

/// A label's node ID and name, from the claim lookup.
public struct LabelRef: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
}

public enum ReviewLabel {
    /// GitHub's limit for label names.
    public static let maxLength = 50

    /// The label name from settings, trimmed, or nil when it is empty or not a usable label name
    /// (too long, or containing control characters). It is only ever sent as a GraphQL variable.
    public static func normalized(_ value: String) -> String? {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...maxLength).contains(name.count),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return name
    }
}
