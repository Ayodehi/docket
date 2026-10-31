import Foundation

/// A change to a PR's reviews on GitHub (docs/design/review-actions.md). Build one with the
/// `make` functions, which validate every identifier before any request is made.
public enum ReviewAction: Sendable, Hashable {
    /// Adds users (logins) and teams (`org/slug`) to the PR's requested reviewers.
    case request(pullRequestID: String, users: [String], teams: [String])
    /// Asks users who already reviewed to review again. User node IDs.
    case rerequest(pullRequestID: String, userIDs: [String])
    /// Dismisses an approving or changes-requested review. The message appears on the PR.
    case dismiss(reviewID: String, message: String)

    public static func makeRequest(pullRequestID: String, users: [String], teams: [String]) throws -> ReviewAction {
        try ReviewInput.checkNodeID(pullRequestID)
        let users = try dedupe(users).map { login in
            guard ReviewInput.isLogin(login) else { throw ReviewInputError.invalidLogin(login) }
            return login
        }
        let teams = try dedupe(teams).map { slug in
            guard ReviewInput.isTeamSlug(slug) else { throw ReviewInputError.invalidTeam(slug) }
            return slug
        }
        guard !users.isEmpty || !teams.isEmpty else { throw ReviewInputError.nothingSelected }
        return .request(pullRequestID: pullRequestID, users: users, teams: teams)
    }

    public static func makeRerequest(pullRequestID: String, userIDs: [String]) throws -> ReviewAction {
        try ReviewInput.checkNodeID(pullRequestID)
        let ids = dedupe(userIDs)
        guard !ids.isEmpty else { throw ReviewInputError.nothingSelected }
        try ids.forEach(ReviewInput.checkNodeID)
        return .rerequest(pullRequestID: pullRequestID, userIDs: ids)
    }

    public static func makeDismiss(reviewID: String, message: String) throws -> ReviewAction {
        try ReviewInput.checkNodeID(reviewID)
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw ReviewInputError.missingReason }
        guard message.count <= ReviewInput.maxReasonLength else { throw ReviewInputError.reasonTooLong }
        return .dismiss(reviewID: reviewID, message: message)
    }

    /// Short name for logs.
    public var name: String {
        switch self {
        case .request: "request"
        case .rerequest: "re-request"
        case .dismiss: "dismiss"
        }
    }

    /// People or teams affected, for logs.
    public var count: Int {
        switch self {
        case .request(_, let users, let teams): users.count + teams.count
        case .rerequest(_, let ids): ids.count
        case .dismiss: 1
        }
    }

    var query: String {
        switch self {
        case .request: Queries.requestReviews
        case .rerequest: Queries.rerequestReviews
        case .dismiss: Queries.dismissReview
        }
    }

    var variables: [String: Any] {
        switch self {
        case .request(let pr, let users, let teams): ["pr": pr, "users": users, "teams": teams]
        case .rerequest(let pr, let ids): ["pr": pr, "users": ids]
        case .dismiss(let review, let message): ["review": review, "message": message]
        }
    }

    private static func dedupe(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { seen.insert($0.lowercased()).inserted }
    }
}

public enum ReviewInputError: Error, Sendable, Equatable {
    case invalidLogin(String)
    case invalidTeam(String)
    case invalidID
    case nothingSelected
    case missingReason
    case reasonTooLong

    public var message: String {
        switch self {
        case .invalidLogin(let login): "“\(login)” is not a valid GitHub username."
        case .invalidTeam(let slug): "“\(slug)” is not a valid team. Use organization/team."
        case .invalidID: "Docket's data for this PR is incomplete. Refresh and try again."
        case .nothingSelected: "Choose at least one reviewer."
        case .missingReason: "Enter a reason. GitHub shows it on the pull request."
        case .reasonTooLong: "The reason is too long."
        }
    }
}

/// Validation for identifiers sent in review actions. Anything that fails is rejected before a
/// request is made, so a crafted value cannot change what is sent.
public enum ReviewInput {
    public static let maxReasonLength = 2000

    /// GitHub usernames: letters, digits, and single hyphens, not at either end, up to 39 characters.
    public static func isLogin(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard (1...39).contains(scalars.count), scalars.first != "-", scalars.last != "-" else { return false }
        var previousHyphen = false
        for scalar in scalars {
            if scalar == "-" {
                if previousHyphen { return false }
                previousHyphen = true
            } else if scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar)) {
                previousHyphen = false
            } else {
                return false
            }
        }
        return true
    }

    /// `org/slug`: an organization login, a slash, and a team slug (lowercase letters, digits,
    /// hyphens, and underscores).
    public static func isTeamSlug(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, isLogin(String(parts[0])) else { return false }
        let slug = parts[1].unicodeScalars
        return (1...100).contains(slug.count) && slug.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.lowercaseLetters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) || scalar == "-" || scalar == "_")
        }
    }

    /// GitHub node IDs are opaque but use a small alphabet (for example `PR_kwDO...` or legacy base64).
    public static func isNodeID(_ value: String) -> Bool {
        (1...200).contains(value.unicodeScalars.count) && value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "_-=+/".unicodeScalars.contains(scalar))
        }
    }

    static func checkNodeID(_ value: String) throws {
        guard isNodeID(value) else { throw ReviewInputError.invalidID }
    }
}
