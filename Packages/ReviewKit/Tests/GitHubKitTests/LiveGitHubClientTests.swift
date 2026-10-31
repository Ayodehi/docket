import Foundation
import Testing
@testable import GitHubKit

final class StubTransport: HTTPTransport, @unchecked Sendable {
    // Only mutated before the client runs in each test.
    var status = 200
    var headers: [String: String] = [:]
    var body = "{}"
    private(set) var lastRequest: URLRequest?

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        return (Data(body.utf8), response)
    }
}

private func client(_ transport: StubTransport, token: String = "test-token") -> LiveGitHubClient {
    LiveGitHubClient(transport: transport, now: { Date(timeIntervalSince1970: 1_000) }, tokenProvider: { token })
}

@Suite struct LiveGitHubClientTests {
    @Test func viewerReadsLoginAndClassicScopes() async throws {
        let stub = StubTransport()
        stub.headers = ["X-OAuth-Scopes": "repo, read:org"]
        stub.body = #"{ "data": { "viewer": { "login": "you" } } }"#
        let info = try await client(stub).viewer()
        #expect(info == TokenInfo(login: "you", scopes: ["repo", "read:org"]))
        #expect(stub.lastRequest?.url == LiveGitHubClient.endpoint)
        #expect(stub.lastRequest?.value(forHTTPHeaderField: "Authorization") == "bearer test-token")
    }

    @Test func fineGrainedTokenHasNoScopes() async throws {
        let stub = StubTransport()
        stub.body = #"{ "data": { "viewer": { "login": "you" } } }"#
        #expect(try await client(stub).viewer().scopes == nil)
    }

    @Test func missingTokenFailsBeforeNetwork() async {
        let stub = StubTransport()
        await #expect(throws: GitHubError.missingToken) { try await client(stub, token: "").viewer() }
        #expect(stub.lastRequest == nil)
    }

    @Test func unauthorized() async {
        let stub = StubTransport()
        stub.status = 401
        await #expect(throws: GitHubError.unauthorized) { try await client(stub).viewer() }
    }

    @Test func ssoRequiredCarriesAuthorizationURL() async {
        let stub = StubTransport()
        stub.status = 403
        stub.headers = ["X-GitHub-SSO": "required; url=https://github.com/orgs/example-org/sso?authorization_request=abc"]
        await #expect(throws: GitHubError.ssoRequired(URL(string: "https://github.com/orgs/example-org/sso?authorization_request=abc"))) {
            try await client(stub).viewer()
        }
    }

    @Test func retryAfterBecomesRateLimited() async {
        let stub = StubTransport()
        stub.status = 403
        stub.headers = ["Retry-After": "60"]
        await #expect(throws: GitHubError.rateLimited(until: Date(timeIntervalSince1970: 1_060))) { try await client(stub).viewer() }
    }

    @Test func primaryLimitExhausted() async {
        let stub = StubTransport()
        stub.status = 403
        stub.headers = ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "2000"]
        await #expect(throws: GitHubError.rateLimited(until: Date(timeIntervalSince1970: 2_000))) { try await client(stub).viewer() }
    }

    @Test func graphQLRateLimitedError() async {
        let stub = StubTransport()
        stub.body = #"{ "errors": [ { "type": "RATE_LIMITED", "message": "API rate limit exceeded" } ] }"#
        await #expect(throws: GitHubError.rateLimited(until: nil)) { try await client(stub).viewer() }
    }

    @Test func gatewayTimeoutIsServerError() async {
        let stub = StubTransport()
        stub.status = 502
        await #expect(throws: GitHubError.server(status: 502)) { try await client(stub).pullRequests(ids: ["PR_1"]) }
    }

    @Test func graphQLErrorsWithoutDataThrowMessages() async {
        let stub = StubTransport()
        stub.body = #"{ "errors": [ { "message": "Field 'nope' doesn't exist" } ] }"#
        await #expect(throws: GitHubError.graphQL(["Field 'nope' doesn't exist"])) { try await client(stub).viewer() }
    }

    @Test func partialDataIsUsed() async throws {
        let stub = StubTransport()
        stub.body = #"{ "data": { "viewer": { "login": "you" } }, "errors": [ { "type": "FORBIDDEN", "message": "Resource protected by organization SAML enforcement." } ] }"#
        #expect(try await client(stub).viewer().login == "you")
    }

    @Test func decodesDetailAndDropsNullNodes() async throws {
        let stub = StubTransport()
        stub.body = #"{ "data": { \#(Fixtures.rateLimit), "nodes": [ \#(Fixtures.detailNode()), null ] } }"#
        let result = try await client(stub).pullRequests(ids: ["PR_482", "PR_gone"])
        let pr = try #require(result.pullRequests.first)
        #expect(result.pullRequests.count == 1)
        #expect(result.rateLimit?.cost == 2)
        #expect(pr.repository.nameWithOwner == "example-org/web-console")
        #expect(pr.reviewRequests.nodes.count == 2)
        #expect(pr.reviewRequests.nodes[1].requestedReviewer?.slug == "web")
        #expect(pr.ciRollup == "SUCCESS")
        #expect(pr.commits.nodes.first?.commit.statusCheckRollup?.contexts?.nodes.map(\.typename) == ["CheckRun", "StatusContext"])
        #expect(pr.reviewThreads.nodes.first?.isResolved == false)
    }

    @Test func discoverySendsAliasedSearchesAndDecodesPages() async throws {
        let stub = StubTransport()
        stub.body = """
        { "data": { "viewer": { "login": "you" }, \(Fixtures.rateLimit),
          "s0": { "issueCount": 2, "pageInfo": { "hasNextPage": true, "endCursor": "c1" }, "nodes": [ \(Fixtures.summaryNode(id: "PR_1")), {} ] },
          "s1": { "issueCount": 1, "pageInfo": { "hasNextPage": false, "endCursor": null }, "nodes": [ \(Fixtures.summaryNode(id: "PR_2", rollup: nil)) ] } } }
        """
        let result = try await client(stub).discover([SearchRequest(query: "q-zero"), SearchRequest(query: "q-one", after: "c0")])
        #expect(result.viewerLogin == "you")
        #expect(result.pages.map(\.hasNextPage) == [true, false])
        #expect(result.pages[0].endCursor == "c1")
        // The empty object (a non-PR search hit) is skipped.
        #expect(result.pages[0].nodes.map(\.id) == ["PR_1"])
        #expect(result.pages[0].nodes[0].ciRollup == "SUCCESS")
        #expect(result.pages[1].nodes[0].ciRollup == nil)

        let body = try #require(stub.lastRequest?.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let variables = try #require(json["variables"] as? [String: Any])
        #expect(variables["q0"] as? String == "q-zero")
        #expect(variables["a0"] is NSNull)
        #expect(variables["a1"] as? String == "c0")
        #expect((json["query"] as? String)?.contains("s1: search(query: $q1") == true)
    }

    @Test func ssoPartialResultsAreFlagged() async throws {
        let stub = StubTransport()
        stub.headers = ["X-GitHub-SSO": "partial-results; organizations=21955855"]
        stub.body = """
        { "data": { "viewer": { "login": "you" }, "s0": { "issueCount": 0, "pageInfo": { "hasNextPage": false, "endCursor": null }, "nodes": [] } } }
        """
        #expect(try await client(stub).discover([SearchRequest(query: "q")]).ssoPartial)
        stub.headers = [:]
        stub.body = """
        { "data": { "viewer": { "login": "you" }, "s0": { "issueCount": 0, "pageInfo": { "hasNextPage": false, "endCursor": null }, "nodes": [] } },
          "errors": [ { "type": "FORBIDDEN", "message": "Resource protected by organization SAML enforcement." } ] }
        """
        #expect(try await client(stub).discover([SearchRequest(query: "q")]).ssoPartial)
        stub.body = #"{ "data": { "viewer": { "login": "you" }, "s0": { "issueCount": 0, "pageInfo": { "hasNextPage": false, "endCursor": null }, "nodes": [] } } }"#
        #expect(try await client(stub).discover([SearchRequest(query: "q")]).ssoPartial == false)
    }

    @Test func decodingErrorsDoNotEchoResponseContent() async {
        let stub = StubTransport()
        stub.body = #"{ "data": { "viewer": { "name": "secret-looking-value" } } }"#
        do {
            _ = try await client(stub).viewer()
            Issue.record("Expected a decoding error")
        } catch let GitHubError.decoding(message) {
            #expect(!message.contains("secret-looking-value"))
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func cachedPullRequestRoundTrips() throws {
        let data = Data(Fixtures.detailNode().utf8)
        let pr = try GitHubJSON.decoder().decode(PullRequest.self, from: data)
        let again = try GitHubJSON.decoder().decode(PullRequest.self, from: GitHubJSON.encoder().encode(pr))
        #expect(pr == again)
    }
}

@Suite struct DiscoverySchemaDriftTests {
    @Test func malformedPullRequestNodeIsAnError() async {
        let stub = StubTransport()
        stub.body = """
        { "data": { "viewer": { "login": "you" },
          "s0": { "issueCount": 1, "pageInfo": { "hasNextPage": false, "endCursor": null }, "nodes": [ { "id": "PR_1", "updatedAt": "not-a-date" } ] } } }
        """
        let client = LiveGitHubClient(transport: stub, tokenProvider: { "t" })
        await #expect(throws: GitHubError.self) { try await client.discover([SearchRequest(query: "q")]) }
    }
}
