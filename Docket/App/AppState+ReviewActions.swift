import Foundation
import GitHubKit
import ReviewCore

/// Requesting, re-requesting, and dismissing reviews (docs/design/review-actions.md).
/// Every action is confirmed in the UI first, runs once, and is never retried automatically.
extension AppState {
    /// Performs `action` on `pr`. On success the updated PR is shown right away and becomes the
    /// notification baseline, since I already know what I just did. Throws a message to show as is.
    func perform(_ action: ReviewAction, on pr: PRSnapshot) async throws {
        guard reviewActionsEnabled else { throw ReviewActionError("Review actions are turned off in Settings > Account.") }
        let target = "\(pr.repo)#\(pr.number)"
        do {
            let updated = try await makeClient().perform(action)
            Log.github.notice("Review action \(action.name, privacy: .public) on \(target, privacy: .public): \(action.count) affected")
            if let engine {
                await engine.apply(actionResult: updated)
                publish(await engine.state, final: false)
                rebaseline(id: pr.id)
            }
        } catch let error as GitHubError {
            Log.github.error("Review action \(action.name, privacy: .public) on \(target, privacy: .public) failed: \(error.kind, privacy: .public)")
            if error == .unauthorized { refresh() }
            throw ReviewActionError(error.reviewActionMessage)
        } catch {
            Log.github.error("Review action \(action.name, privacy: .public) on \(target, privacy: .public) failed")
            throw ReviewActionError("The request did not complete. Check the PR on GitHub before trying again.")
        }
    }

    func suggestedReviewers(for pr: PRSnapshot) async -> [String] {
        (try? await makeClient().suggestedReviewers(pullRequestID: pr.id)) ?? []
    }

    /// Teams I can request on this PR: mine in the repo's organization. Typed team names are not accepted.
    func requestableTeams(for pr: PRSnapshot) -> [String] {
        let org = (pr.repo.split(separator: "/").first.map(String.init) ?? "").lowercased()
        let mine = myTeams.filter { $0.lowercased().hasPrefix(org + "/") }
        return mine.sorted()
    }
}

struct ReviewActionError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension GitHubError {
    /// Error kind for logs, without GitHub's message text.
    var kind: String {
        switch self {
        case .missingToken: "missingToken"
        case .unauthorized: "unauthorized"
        case .ssoRequired: "ssoRequired"
        case .rateLimited: "rateLimited"
        case .server(let status): "server \(status)"
        case .http(let status): "http \(status)"
        case .graphQL: "graphQL"
        case .transport: "transport"
        case .decoding: "decoding"
        }
    }

    /// GitHub's own message where it gave one, with a hint for the common permission failure.
    var reviewActionMessage: String {
        switch self {
        case .graphQL(let messages):
            let text = messages.joined(separator: " ")
            if text.localizedCaseInsensitiveContains("not accessible by") {
                return "GitHub says: \(text) The token needs Pull requests: write for this repository."
            }
            return "GitHub says: \(text)"
        case .http(403):
            return "GitHub refused the request (HTTP 403). The token may lack Pull requests: write, or branch protection may restrict this."
        case .server, .transport:
            return userMessage + " The change may or may not have been made; check the PR on GitHub before trying again."
        default:
            return userMessage
        }
    }
}
