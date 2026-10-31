import Foundation

/// Fictional responses shaped like real GitHub GraphQL output.
enum Fixtures {
    static func detailNode(id: String = "PR_482", number: Int = 482, state: String = "OPEN", mergeable: String = "MERGEABLE") -> String {
        """
        {
          "id": "\(id)", "number": \(number), "title": "Add audit log filters to project view",
          "url": "https://github.com/example-org/web-console/pull/\(number)", "state": "\(state)", "isDraft": false,
          "createdAt": "2026-10-13T06:00:00Z", "updatedAt": "2026-10-13T09:00:00Z",
          "additions": 312, "deletions": 45, "changedFiles": 9,
          "author": { "login": "mchen", "avatarUrl": "https://avatars.example.com/u/1" },
          "repository": { "nameWithOwner": "example-org/web-console", "isArchived": false },
          "headRefName": "mchen/audit-filters", "headRefOid": "abc123", "baseRefName": "main",
          "headRepository": { "nameWithOwner": "example-org/web-console" },
          "isCrossRepository": false, "reviewDecision": "REVIEW_REQUIRED",
          "mergeable": "\(mergeable)", "mergeStateStatus": "BLOCKED",
          "labels": { "nodes": [ { "name": "frontend", "color": "38c0c7" } ] },
          "reviewRequests": { "nodes": [
            { "requestedReviewer": { "__typename": "User", "login": "you" } },
            { "requestedReviewer": { "__typename": "Team", "slug": "web", "organization": { "login": "example-org" } } },
            null
          ] },
          "latestOpinionatedReviews": { "nodes": [ { "author": { "login": "asokolov" }, "state": "APPROVED", "submittedAt": "2026-10-13T08:00:00Z", "commit": { "oid": "abc123" } } ] },
          "latestReviews": { "nodes": [ { "author": { "login": "asokolov" }, "state": "APPROVED", "submittedAt": "2026-10-13T08:00:00Z" } ] },
          "comments": { "nodes": [ { "author": { "login": "asokolov" }, "createdAt": "2026-10-13T08:30:00Z" }, null ] },
          "reviewThreads": { "totalCount": 1, "nodes": [ { "isResolved": false, "comments": { "nodes": [ { "author": { "login": "asokolov" }, "createdAt": "2026-10-13T08:00:00Z" } ] } } ] },
          "commits": { "nodes": [ { "commit": { "oid": "abc123", "committedDate": "2026-10-13T07:00:00Z",
            "statusCheckRollup": { "state": "SUCCESS", "contexts": { "nodes": [
              { "__typename": "CheckRun", "name": "build", "status": "COMPLETED", "conclusion": "SUCCESS", "detailsUrl": "https://ci.example.com/1", "startedAt": "2026-10-13T07:01:00Z", "completedAt": "2026-10-13T07:04:12Z" },
              { "__typename": "StatusContext", "context": "lint", "state": "SUCCESS", "targetUrl": null, "createdAt": "2026-10-13T07:02:00Z" }
            ] } } } } ] }
        }
        """
    }

    static func summaryNode(id: String, updatedAt: String = "2026-10-13T09:00:00Z", rollup: String? = "SUCCESS") -> String {
        let commit = rollup.map { #"{ "commit": { "statusCheckRollup": { "state": "\#($0)" } } }"# } ?? #"{ "commit": { "statusCheckRollup": null } }"#
        return """
        { "id": "\(id)", "updatedAt": "\(updatedAt)", "headRefOid": "sha-\(id)", "isDraft": false, "reviewDecision": null, "commits": { "nodes": [ \(commit) ] } }
        """
    }

    static let rateLimit = #""rateLimit": { "cost": 2, "remaining": 4990, "resetAt": "2026-10-13T10:00:00Z", "limit": 5000 }"#
}
