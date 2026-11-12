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

@Suite struct ReviewClaimTests {
    @Test func labelNames() {
        #expect(ReviewLabel.normalized("  In Review ") == "In Review")
        #expect(ReviewLabel.normalized("status: reviewing 👀") == "status: reviewing 👀")
        #expect(ReviewLabel.normalized("") == nil)
        #expect(ReviewLabel.normalized("   ") == nil)
        #expect(ReviewLabel.normalized("a\nb") == nil)
        #expect(ReviewLabel.normalized("a\u{0}b") == nil)
        #expect(ReviewLabel.normalized(String(repeating: "x", count: 51)) == nil)
    }

    @Test func actionsValidateIDs() {
        #expect(throws: ReviewInputError.invalidID) { try ClaimAction.makeAssign(pullRequestID: "PR_1", userID: "U 1") }
        #expect(throws: ReviewInputError.invalidID) { try ClaimAction.makeAddLabel(pullRequestID: "PR\"1", labelID: "LA_1") }
        #expect(throws: ReviewInputError.invalidID) { try ClaimAction.makeRemoveLabel(pullRequestID: "PR_1", labelID: "") }
    }

    @Test func lookupSendsLabelAsVariableAndMatchesCaseInsensitively() async throws {
        let stub = StubTransport()
        stub.body = #"""
        { "data": { "viewer": { "id": "U_me" }, "repository": { "labels": { "nodes": [
          { "id": "LA_2", "name": "in review later" }, { "id": "LA_1", "name": "In Review" } ] } } } }
        """#
        let label = #"in review") { x } query { y"#
        let targets = try await client(stub).claimTargets(repo: "example-org/web-console", label: "in review")
        #expect(targets == ClaimTargets(viewerID: "U_me", labelID: "LA_1", labelName: "In Review"))
        _ = try? await client(stub).claimTargets(repo: "example-org/web-console", label: label)
        let sent = try sentBody(stub)
        #expect(!sent.query.contains("in review"))
        #expect(sent.variables["label"] as? String == label)
        #expect(sent.variables["owner"] as? String == "example-org")
        #expect(sent.variables["name"] as? String == "web-console")
        #expect(sent.variables["withLabel"] as? Bool == true)
    }

    @Test func lookupWithoutLabel() async throws {
        let stub = StubTransport()
        stub.body = #"{ "data": { "viewer": { "id": "U_me" }, "repository": {} } }"#
        let targets = try await client(stub).claimTargets(repo: "example-org/web-console", label: nil)
        #expect(targets == ClaimTargets(viewerID: "U_me", labelID: nil, labelName: nil))
        #expect(try sentBody(stub).variables["withLabel"] as? Bool == false)
    }

    @Test func missingLabelIsNil() async throws {
        let stub = StubTransport()
        stub.body = #"{ "data": { "viewer": { "id": "U_me" }, "repository": { "labels": { "nodes": [ { "id": "LA_2", "name": "In Review Later" } ] } } } }"#
        let targets = try await client(stub).claimTargets(repo: "example-org/web-console", label: "In Review")
        #expect(targets.labelID == nil)
    }

    @Test func badRepoIsRejectedBeforeRequest() async {
        let stub = StubTransport()
        await #expect(throws: ReviewInputError.invalidID) { try await client(stub).claimTargets(repo: "web-console", label: nil) }
        #expect(stub.lastRequest == nil)
    }

    @Test func mutationsKeepExistingValuesAndSendIDsAsVariables() async throws {
        let stub = StubTransport()
        stub.body = #"{ "data": { "addAssigneesToAssignable": { "assignable": \#(Fixtures.detailNode()) } } }"#
        let assigned = try await client(stub).perform(try ClaimAction.makeAssign(pullRequestID: "PR_482", userID: "U_me"))
        #expect(assigned.id == "PR_482")
        var sent = try sentBody(stub)
        #expect(sent.query.contains("addAssigneesToAssignable"))
        #expect(sent.variables["pr"] as? String == "PR_482")
        #expect(sent.variables["ids"] as? [String] == ["U_me"])

        stub.body = #"{ "data": { "addLabelsToLabelable": { "labelable": \#(Fixtures.detailNode()) } } }"#
        _ = try await client(stub).perform(try ClaimAction.makeAddLabel(pullRequestID: "PR_482", labelID: "LA_1"))
        sent = try sentBody(stub)
        #expect(sent.query.contains("addLabelsToLabelable"))
        #expect(sent.variables["ids"] as? [String] == ["LA_1"])

        stub.body = #"{ "data": { "removeLabelsFromLabelable": { "labelable": \#(Fixtures.detailNode()) } } }"#
        _ = try await client(stub).perform(try ClaimAction.makeRemoveLabel(pullRequestID: "PR_482", labelID: "LA_1"))
        sent = try sentBody(stub)
        #expect(sent.query.contains("removeLabelsFromLabelable"))
        #expect(sent.variables["ids"] as? [String] == ["LA_1"])
    }

    @Test func permissionErrorIsReportedAndNotRetried() async throws {
        let stub = CountingTransport(status: 403)
        let client = LiveGitHubClient(transport: stub, tokenProvider: { "test-token" })
        await #expect(throws: GitHubError.http(status: 403)) {
            try await client.perform(try ClaimAction.makeAddLabel(pullRequestID: "PR_1", labelID: "LA_1"))
        }
        #expect(stub.count == 1)
    }
}
