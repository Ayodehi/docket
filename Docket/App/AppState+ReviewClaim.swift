import Foundation
import GitHubKit
import ReviewCore

/// Settings > Account: what Docket does on GitHub when I start reviewing someone else's PR.
struct ReviewClaimSettings: Codable, Equatable {
    /// Add me to the PR's assignees.
    var assignMe = false
    /// Label to add, such as "In Review". Empty for none.
    var label = ""
    /// Remove the label Docket added once my review is posted.
    var removeLabelWhenPosted = true

    init() {}

    /// Missing keys (settings saved by an earlier version) fall back to defaults.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ReviewClaimSettings()
        assignMe = try c.decodeIfPresent(Bool.self, forKey: .assignMe) ?? d.assignMe
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? d.label
        removeLabelWhenPosted = try c.decodeIfPresent(Bool.self, forKey: .removeLabelWhenPosted) ?? d.removeLabelWhenPosted
    }

    /// The label to add, or nil when none is set or the name is not usable.
    var labelName: String? { ReviewLabel.normalized(label) }

    var isActive: Bool { assignMe || labelName != nil }
}

private let claimsFile = "review-claims.json"

/// Assigning me and labelling a PR when a review session starts, and removing the label once my
/// review is posted (docs/design/review-claim.md). Each write runs once; only label removal is
/// tried again, on the next sync, after a network or server error.
extension AppState {
    /// Called after Claude starts a review session on `pr`. Does nothing for my own PRs or with the
    /// settings off. Problems are shown after the fact; they never stop the session.
    func claimForReview(_ pr: PRSnapshot) {
        let settings = reviewClaimSettings
        guard !pr.isMine, settings.isActive else { return }
        let wanted = settings.labelName
        let target = "\(pr.repo)#\(pr.number)"
        Task {
            let client = makeClient()
            var problems: [String] = []
            do {
                let targets = try await client.claimTargets(repo: pr.repo, label: wanted)
                if settings.assignMe {
                    do {
                        let updated = try await client.perform(try ClaimAction.makeAssign(pullRequestID: pr.id, userID: targets.viewerID))
                        Log.github.notice("Review claim: assigned on \(target, privacy: .public)")
                        await applyWriteResult(updated)
                    } catch {
                        problems.append("Assigning you failed. " + claimMessage(error, action: "assign", target: target))
                    }
                }
                if let wanted {
                    if let labelID = targets.labelID, let name = targets.labelName {
                        // A label already on the PR was put there by someone else (or by me on GitHub):
                        // leave it, and do not take it off later.
                        if !pr.labels.contains(where: { $0.lowercased() == name.lowercased() }) {
                            do {
                                let updated = try await client.perform(try ClaimAction.makeAddLabel(pullRequestID: pr.id, labelID: labelID))
                                Log.github.notice("Review claim: label added on \(target, privacy: .public)")
                                if settings.removeLabelWhenPosted, let viewer = viewerLogin {
                                    recordClaim(PendingClaim(prID: pr.id, repo: pr.repo, number: pr.number, labelID: labelID, labelName: name,
                                                             priorReviewAt: ReviewClaims.latestReview(by: viewer, on: updated), claimedAt: Date()))
                                }
                                await applyWriteResult(updated)
                            } catch {
                                problems.append("Adding the label failed. " + claimMessage(error, action: "add label", target: target))
                            }
                        }
                    } else {
                        problems.append("\(pr.repo) has no label named “\(wanted)”. Docket does not create labels: add it to the repository on GitHub, or change the name in Settings > Account.")
                    }
                }
            } catch {
                problems.append(claimMessage(error, action: "lookup", target: target))
            }
            if !problems.isEmpty {
                show(title: "Claude started, but \(pr.repoName) #\(pr.number) was not fully marked", message: problems.joined(separator: "\n\n"))
            }
        }
    }

    /// After each full sync: removes labels whose reviews are now posted, and drops claims with
    /// nothing left to do.
    func releaseClaims(now: Date) {
        guard !pendingClaims.isEmpty, !isReleasingClaims, let viewer = viewerLogin else { return }
        var drop: Set<String> = []
        var remove: [PendingClaim] = []
        for claim in pendingClaims {
            switch ReviewClaims.decide(claim, pr: detail(id: claim.prID), viewer: viewer, now: now) {
            case .wait: break
            case .drop: drop.insert(claim.prID)
            case .removeLabel: remove.append(claim)
            }
        }
        if !drop.isEmpty {
            pendingClaims.removeAll { drop.contains($0.prID) }
            saveClaims()
        }
        guard !remove.isEmpty else { return }
        isReleasingClaims = true
        Task {
            defer {
                isReleasingClaims = false
                saveClaims()
            }
            let client = makeClient()
            for claim in remove {
                let target = "\(claim.repo)#\(claim.number)"
                do {
                    let updated = try await client.perform(try ClaimAction.makeRemoveLabel(pullRequestID: claim.prID, labelID: claim.labelID))
                    Log.github.notice("Review claim: label removed on \(target, privacy: .public) after review posted")
                    pendingClaims.removeAll { $0.prID == claim.prID }
                    await applyWriteResult(updated)
                } catch let error as GitHubError where error.isTransient {
                    Log.github.error("Review claim: label removal on \(target, privacy: .public) failed: \(error.kind, privacy: .public)")
                    guard let index = pendingClaims.firstIndex(where: { $0.prID == claim.prID }) else { continue }
                    pendingClaims[index].failures += 1
                    if pendingClaims[index].failures >= ReviewClaims.maxFailures {
                        pendingClaims.remove(at: index)
                        show(title: "Label not removed from \(claim.repo) #\(claim.number)",
                             message: "Your review is posted, but Docket could not remove “\(claim.labelName)” after \(ReviewClaims.maxFailures) tries. Remove it on GitHub.")
                    }
                } catch {
                    pendingClaims.removeAll { $0.prID == claim.prID }
                    show(title: "Label not removed from \(claim.repo) #\(claim.number)",
                         message: "Your review is posted, but Docket could not remove “\(claim.labelName)”. "
                            + claimMessage(error, action: "remove label", target: target))
                }
            }
        }
    }

    func loadClaims() {
        pendingClaims = (try? files?.load([PendingClaim].self, from: claimsFile, decoder: GitHubJSON.decoder())) ?? []
    }

    func saveClaims() {
        try? files?.save(pendingClaims, as: claimsFile, encoder: GitHubJSON.encoder())
    }

    private func recordClaim(_ claim: PendingClaim) {
        pendingClaims.removeAll { $0.prID == claim.prID }
        pendingClaims.append(claim)
        saveClaims()
    }

    /// Logs the failure and returns text to show.
    private func claimMessage(_ error: any Error, action: String, target: String) -> String {
        switch error {
        case let error as GitHubError:
            Log.github.error("Review claim \(action, privacy: .public) on \(target, privacy: .public) failed: \(error.kind, privacy: .public)")
            if error == .unauthorized { refresh() }
            switch error {
            case .graphQL(let messages):
                let text = messages.joined(separator: " ")
                if text.localizedCaseInsensitiveContains("not accessible by") {
                    return "GitHub says: \(text) The token needs Pull requests: write for this repository."
                }
                return "GitHub says: \(text)"
            case .http(403):
                return "GitHub refused the request (HTTP 403). The token may lack Pull requests: write for this repository."
            default:
                return error.userMessage
            }
        case let error as ReviewInputError:
            Log.github.error("Review claim \(action, privacy: .public) on \(target, privacy: .public) failed: invalid input")
            return error.message
        default:
            Log.github.error("Review claim \(action, privacy: .public) on \(target, privacy: .public) failed")
            return "The request did not complete."
        }
    }
}

extension GitHubError {
    /// Worth trying again later: the request may not have reached GitHub, or GitHub was busy.
    var isTransient: Bool {
        switch self {
        case .transport, .server, .rateLimited: true
        default: false
        }
    }
}
