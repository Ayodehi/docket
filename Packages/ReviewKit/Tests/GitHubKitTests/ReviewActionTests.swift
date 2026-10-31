import Foundation
import Testing
@testable import GitHubKit

private func client(_ transport: StubTransport) -> LiveGitHubClient {
    LiveGitHubClient(transport: transport, now: { Date(timeIntervalSince1970: 1_000) }, tokenProvider: { "test-token" })
}

private func sentBody(_ stub: StubTransport) throws -> (query: String, variables: [String: Any]) {
    let body = try #require(stub.lastRequest?.httpBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    return (try #require(json["query"] as? String), json["variables"] as? [String: Any] ?? [:])
}

@Suite struct ReviewInputTests {
    @Test(arguments: ["mchen", "a", "a-b", "A1-b2-c3", String(repeating: "x", count: 39)])
    func validLogins(_ login: String) {
        #expect(ReviewInput.isLogin(login))
    }

    @Test(arguments: ["", "-a", "a-", "a--b", "a b", "a_b", "a/b", "a.b", "é", "a\"b", "a\nb", "a\\b", "$(id)", "a;b",
                      String(repeating: "x", count: 40), "ｍchen", "a\u{0}b"])
    func hostileOrInvalidLogins(_ login: String) {
        #expect(!ReviewInput.isLogin(login))
    }

    @Test func teamSlugs() {
        #expect(ReviewInput.isTeamSlug("example-org/web"))
        #expect(ReviewInput.isTeamSlug("example-org/platform_team-2"))
        #expect(!ReviewInput.isTeamSlug("web"))
        #expect(!ReviewInput.isTeamSlug("example-org/"))
        #expect(!ReviewInput.isTeamSlug("/web"))
        #expect(!ReviewInput.isTeamSlug("example-org/web/extra"))
        #expect(!ReviewInput.isTeamSlug("example-org/Web"))
        #expect(!ReviewInput.isTeamSlug("example-org/we b"))
        #expect(!ReviewInput.isTeamSlug("-org/web"))
    }

    @Test func nodeIDs() {
        #expect(ReviewInput.isNodeID("PR_kwDOAbc123"))
        #expect(ReviewInput.isNodeID("MDQ6VXNlcjE="))
        #expect(!ReviewInput.isNodeID(""))
        #expect(!ReviewInput.isNodeID("PR 1"))
        #expect(!ReviewInput.isNodeID("PR\"}"))
        #expect(!ReviewInput.isNodeID(String(repeating: "A", count: 201)))
    }

    @Test func requestValidatesAndDedupes() throws {
        let action = try ReviewAction.makeRequest(pullRequestID: "PR_1", users: ["mchen", "MChen", " asokolov "], teams: ["example-org/web"])
        #expect(action == .request(pullRequestID: "PR_1", users: ["mchen", "asokolov"], teams: ["example-org/web"]))
        #expect(throws: ReviewInputError.invalidLogin("bad user")) { try ReviewAction.makeRequest(pullRequestID: "PR_1", users: ["bad user"], teams: []) }
        #expect(throws: ReviewInputError.invalidTeam("web")) { try ReviewAction.makeRequest(pullRequestID: "PR_1", users: [], teams: ["web"]) }
        #expect(throws: ReviewInputError.nothingSelected) { try ReviewAction.makeRequest(pullRequestID: "PR_1", users: [], teams: []) }
        #expect(throws: ReviewInputError.invalidID) { try ReviewAction.makeRequest(pullRequestID: "PR\"1", users: ["mchen"], teams: []) }
    }

    @Test func dismissNeedsAReason() throws {
        #expect(throws: ReviewInputError.missingReason) { try ReviewAction.makeDismiss(reviewID: "PRR_1", message: "  \n ") }
        #expect(throws: ReviewInputError.reasonTooLong) { try ReviewAction.makeDismiss(reviewID: "PRR_1", message: String(repeating: "x", count: 2001)) }
        #expect(try ReviewAction.makeDismiss(reviewID: "PRR_1", message: " Addressed in abc123 \n") == .dismiss(reviewID: "PRR_1", message: "Addressed in abc123"))
    }

    @Test func rerequestNeedsUsers() {
        #expect(throws: ReviewInputError.nothingSelected) { try ReviewAction.makeRerequest(pullRequestID: "PR_1", userIDs: []) }
        #expect(throws: ReviewInputError.invalidID) { try ReviewAction.makeRerequest(pullRequestID: "PR_1", userIDs: ["U 1"]) }
    }
}

@Suite struct ReviewActionClientTests {
    @Test func requestAlwaysAddsAndSendsValuesAsVariables() async throws {
        let stub = StubTransport()
        stub.body = #"{ "data": { "requestReviewsByLogin": { "pullRequest": \#(Fixtures.detailNode()) } } }"#
        let pr = try await client(stub).perform(try ReviewAction.makeRequest(pullRequestID: "PR_482", users: ["asokolov"], teams: ["example-org/web"]))
        #expect(pr.id == "PR_482")
        let sent = try sentBody(stub)
        #expect(sent.query.contains("union: true"))
        #expect(!sent.query.contains("asokolov"))
        #expect(!sent.query.contains("example-org/web"))
        #expect(sent.variables["pr"] as? String == "PR_482")
        #expect(sent.variables["users"] as? [String] == ["asokolov"])
        #expect(sent.variables["teams"] as? [String] == ["example-org/web"])
    }

    @Test func dismissSendsReasonAsVariable() async throws {
        let stub = StubTransport()
        stub.body = #"{ "data": { "dismissPullRequestReview": { "pullRequestReview": { "pullRequest": \#(Fixtures.detailNode()) } } } }"#
        let reason = #"Fixed in abc123") { x } mutation { y"#
        _ = try await client(stub).perform(try ReviewAction.makeDismiss(reviewID: "PRR_9", message: reason))
        let sent = try sentBody(stub)
        #expect(!sent.query.contains("Fixed in"))
        #expect(sent.variables["review"] as? String == "PRR_9")
        #expect(sent.variables["message"] as? String == reason)
    }

    @Test func rerequestSendsUserIDs() async throws {
        let stub = StubTransport()
        stub.body = #"{ "data": { "rerequestReviews": { "pullRequest": \#(Fixtures.detailNode()) } } }"#
        _ = try await client(stub).perform(try ReviewAction.makeRerequest(pullRequestID: "PR_482", userIDs: ["U_1"]))
        let sent = try sentBody(stub)
        #expect(sent.query.contains("rerequestReviews"))
        #expect(sent.variables["users"] as? [String] == ["U_1"])
    }

    @Test func graphQLErrorWithNullPayloadIsReported() async throws {
        let stub = StubTransport()
        stub.body = #"{ "data": { "dismissPullRequestReview": null }, "errors": [ { "type": "FORBIDDEN", "message": "Resource not accessible by personal access token" } ] }"#
        await #expect(throws: GitHubError.graphQL(["Resource not accessible by personal access token"])) {
            try await client(stub).perform(try ReviewAction.makeDismiss(reviewID: "PRR_9", message: "Done"))
        }
    }

    @Test func http403IsNotRetried() async throws {
        let stub = CountingTransport(status: 403)
        let client = LiveGitHubClient(transport: stub, tokenProvider: { "test-token" })
        await #expect(throws: GitHubError.http(status: 403)) {
            try await client.perform(try ReviewAction.makeRerequest(pullRequestID: "PR_1", userIDs: ["U_1"]))
        }
        #expect(stub.count == 1)
    }

    @Test func serverErrorIsNotRetried() async throws {
        let stub = CountingTransport(status: 502)
        let client = LiveGitHubClient(transport: stub, tokenProvider: { "test-token" })
        await #expect(throws: GitHubError.server(status: 502)) {
            try await client.perform(try ReviewAction.makeRequest(pullRequestID: "PR_1", users: ["mchen"], teams: []))
        }
        #expect(stub.count == 1)
    }

    @Test func suggestionsDropBotsAndAuthor() async throws {
        let stub = StubTransport()
        stub.body = #"""
        { "data": { "node": { "suggestedReviewerActors": { "nodes": [
          { "isAuthor": false, "reviewer": { "__typename": "User", "login": "asokolov" } },
          { "isAuthor": true, "reviewer": { "__typename": "User", "login": "mchen" } },
          { "isAuthor": false, "reviewer": { "__typename": "Bot", "login": "review-bot" } }
        ] } } } }
        """#
        #expect(try await client(stub).suggestedReviewers(pullRequestID: "PR_1") == ["asokolov"])
    }

    @Test func detailDecodesReviewAndUserIDs() async throws {
        let stub = StubTransport()
        let node = Fixtures.detailNode()
            .replacingOccurrences(of: #"{ "author": { "login": "asokolov" }, "state": "APPROVED", "submittedAt": "2026-10-13T08:00:00Z", "commit""#,
                                  with: #"{ "id": "PRR_7", "author": { "login": "asokolov", "id": "U_7" }, "state": "APPROVED", "submittedAt": "2026-10-13T08:00:00Z", "commit""#)
        stub.body = #"{ "data": { "nodes": [ \#(node) ] } }"#
        let pr = try #require(try await client(stub).pullRequests(ids: ["PR_482"]).pullRequests.first)
        #expect(pr.latestOpinionatedReviews.nodes.first?.id == "PRR_7")
        #expect(pr.latestOpinionatedReviews.nodes.first?.author?.id == "U_7")
    }
}

final class CountingTransport: HTTPTransport, @unchecked Sendable {
    let status: Int
    private(set) var count = 0
    init(status: Int) { self.status = status }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count += 1
        return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!)
    }
}
