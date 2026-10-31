import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPTransport {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// GraphQL client for api.github.com. The token is read from `tokenProvider` for each request
/// and never stored on the client, logged, or included in errors.
public final class LiveGitHubClient: GitHubClient {
    public static let endpoint = URL(string: "https://api.github.com/graphql")!

    private let transport: any HTTPTransport
    private let tokenProvider: @Sendable () throws -> String
    private let now: @Sendable () -> Date

    public init(
        transport: any HTTPTransport = URLSession(configuration: .ephemeral),
        now: @escaping @Sendable () -> Date = { Date() },
        tokenProvider: @escaping @Sendable () throws -> String
    ) {
        self.transport = transport
        self.now = now
        self.tokenProvider = tokenProvider
    }

    public func viewer() async throws -> TokenInfo {
        struct Data: Decodable { struct Viewer: Decodable { var login: String }; var viewer: Viewer }
        let (data, response) = try await post(query: Queries.viewer, variables: [:])
        let decoded: Data = try decodeData(data)
        let scopes = response.value(forHTTPHeaderField: "X-OAuth-Scopes").map { header in
            header.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return TokenInfo(login: decoded.viewer.login, scopes: scopes)
    }

    public func discover(_ requests: [SearchRequest]) async throws -> DiscoveryResult {
        guard !requests.isEmpty else { throw GitHubError.graphQL(["No searches requested"]) }
        var variables: [String: Any] = [:]
        for (index, request) in requests.enumerated() {
            variables["q\(index)"] = request.query
            variables["a\(index)"] = request.after ?? NSNull()
        }
        let (data, response) = try await post(query: Queries.discovery(count: requests.count), variables: variables)
        let decoded: DiscoveryData = try decodeData(data)
        let pages = try (0..<requests.count).map { index in
            guard let page = decoded.searches["s\(index)"] else { throw GitHubError.decoding("Missing search s\(index)") }
            return page
        }
        let ssoPartial = response.value(forHTTPHeaderField: "X-GitHub-SSO")?.lowercased().hasPrefix("partial-results") == true
            || Self.mentionsSAML(data)
        return DiscoveryResult(viewerLogin: decoded.viewerLogin, rateLimit: decoded.rateLimit, pages: pages, ssoPartial: ssoPartial)
    }

    public func pullRequests(ids: [String]) async throws -> DetailResult {
        struct Data: Decodable { var rateLimit: RateLimitInfo?; var nodes: [PullRequest?] }
        let (data, _) = try await post(query: Queries.detail, variables: ["ids": ids])
        let decoded: Data = try decodeData(data)
        return DetailResult(pullRequests: decoded.nodes.compactMap { $0 }, rateLimit: decoded.rateLimit)
    }

    public func teams(login: String) async throws -> Set<String> {
        struct Data: Decodable {
            struct Viewer: Decodable { var organizations: Connection<Org> }
            struct Org: Codable, Sendable, Hashable { var login: String; var teams: Connection<Team> }
            struct Team: Codable, Sendable, Hashable { var slug: String }
            var viewer: Viewer
        }
        let (data, _) = try await post(query: Queries.teams, variables: ["login": login])
        let decoded: Data = try decodeData(data)
        return Set(decoded.viewer.organizations.nodes.flatMap { org in org.teams.nodes.map { "\(org.login)/\($0.slug)" } })
    }

    // MARK: - Review actions

    /// Performs one review action and returns the PR as GitHub has it afterward. Never retried:
    /// on any error the caller shows it and the user decides whether to try again.
    public func perform(_ action: ReviewAction) async throws -> PullRequest {
        struct Request: Decodable { struct Payload: Decodable { var pullRequest: PullRequest? }; var requestReviewsByLogin: Payload? }
        struct Rerequest: Decodable { struct Payload: Decodable { var pullRequest: PullRequest? }; var rerequestReviews: Payload? }
        struct Dismiss: Decodable {
            struct Payload: Decodable { struct Review: Decodable { var pullRequest: PullRequest? }; var pullRequestReview: Review? }
            var dismissPullRequestReview: Payload?
        }
        let (data, _) = try await post(query: action.query, variables: action.variables)
        let pr: PullRequest?
        switch action {
        case .request: pr = (try decodeMutation(data) as Request).requestReviewsByLogin?.pullRequest
        case .rerequest: pr = (try decodeMutation(data) as Rerequest).rerequestReviews?.pullRequest
        case .dismiss: pr = (try decodeMutation(data) as Dismiss).dismissPullRequestReview?.pullRequestReview?.pullRequest
        }
        guard let pr else { throw GitHubError.decoding("Response had no pull request") }
        return pr
    }

    /// Logins GitHub suggests as reviewers for a PR, without bots or the author.
    public func suggestedReviewers(pullRequestID: String) async throws -> [String] {
        struct Data: Decodable {
            struct Node: Decodable { var suggestedReviewerActors: Connection<Suggestion>? }
            struct Suggestion: Codable, Sendable, Hashable {
                struct Actor: Codable, Sendable, Hashable { var __typename: String; var login: String }
                var isAuthor: Bool
                var reviewer: Actor
            }
            var node: Node?
        }
        try ReviewInput.checkNodeID(pullRequestID)
        let (data, _) = try await post(query: Queries.suggestedReviewers, variables: ["pr": pullRequestID])
        let decoded: Data = try decodeData(data)
        return (decoded.node?.suggestedReviewerActors?.nodes ?? [])
            .filter { !$0.isAuthor && $0.reviewer.__typename == "User" && ReviewInput.isLogin($0.reviewer.login) }
            .map(\.reviewer.login)
    }

    // MARK: - Transport

    private func post(query: String, variables: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        let token: String
        do { token = try tokenProvider() } catch { throw GitHubError.missingToken }
        guard !token.isEmpty else { throw GitHubError.missingToken }

        var request = URLRequest(url: Self.endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Docket", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as URLError {
            throw GitHubError.transport("URLError \(error.code.rawValue)")
        }
        try checkStatus(response, data: data)
        return (data, response)
    }

    private func checkStatus(_ response: HTTPURLResponse, data: Data) throws {
        if let sso = response.value(forHTTPHeaderField: "X-GitHub-SSO"), sso.lowercased().hasPrefix("required") {
            throw GitHubError.ssoRequired(Self.ssoURL(from: sso))
        }
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw GitHubError.unauthorized
        case 403, 429:
            if let retryAfter = response.value(forHTTPHeaderField: "Retry-After"), let seconds = TimeInterval(retryAfter) {
                throw GitHubError.rateLimited(until: now().addingTimeInterval(seconds))
            }
            if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
                throw GitHubError.rateLimited(until: reset)
            }
            throw GitHubError.http(status: response.statusCode)
        case 500..<600:
            throw GitHubError.server(status: response.statusCode)
        default:
            throw GitHubError.http(status: response.statusCode)
        }
    }

    /// GraphQL reports SAML-protected resources as errors alongside partial data.
    static func mentionsSAML(_ data: Data) -> Bool {
        struct Errors: Decodable { struct E: Decodable { var message: String }; var errors: [E]? }
        let errors = (try? JSONDecoder().decode(Errors.self, from: data))?.errors ?? []
        return errors.contains { $0.message.contains("SAML") }
    }

    /// Parses `required; url=https://github.com/orgs/<org>/sso?...`.
    static func ssoURL(from header: String) -> URL? {
        header.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("url=") }
            .flatMap { URL(string: String($0.dropFirst(4))) }
    }

    private func decodeData<T: Decodable>(_ data: Data) throws -> T {
        let envelope: Envelope<T>
        do {
            envelope = try GitHubJSON.decoder().decode(Envelope<T>.self, from: data)
        } catch let error as DecodingError {
            throw GitHubError.decoding(Self.describe(error))
        }
        if let errors = envelope.errors, !errors.isEmpty {
            if errors.contains(where: { $0.type == "RATE_LIMITED" }) { throw GitHubError.rateLimited(until: nil) }
            // Partial data (for example one SAML-protected org) is still usable.
            if envelope.data == nil { throw GitHubError.graphQL(errors.map(\.message)) }
        }
        guard let value = envelope.data else { throw GitHubError.decoding("Response had no data") }
        return value
    }

    /// Mutations fail as a whole: any GraphQL error (for example no permission, or branch
    /// protection) is reported, even when `data` is present with a null payload.
    private func decodeMutation<T: Decodable>(_ data: Data) throws -> T {
        if let errors = (try? JSONDecoder().decode(MutationErrors.self, from: data))?.errors, !errors.isEmpty {
            if errors.contains(where: { $0.type == "RATE_LIMITED" }) { throw GitHubError.rateLimited(until: nil) }
            throw GitHubError.graphQL(errors.map(\.message))
        }
        return try decodeData(data)
    }

    /// Describes where decoding failed without echoing response content.
    static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context): return "Missing \(key.stringValue) at \(path(context))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context): return "Bad value at \(path(context))"
        @unknown default: return "Decoding failed"
        }
    }
}

private struct MutationErrors: Decodable {
    var errors: [Envelope<Bool>.GraphQLError]?
}

private struct Envelope<T: Decodable>: Decodable {
    struct GraphQLError: Decodable { var message: String; var type: String? }
    var data: T?
    var errors: [GraphQLError]?
}

/// Decodes `viewer`, `rateLimit`, and any number of aliased searches `s0, s1, ...`.
struct DiscoveryData: Decodable {
    struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
    struct Viewer: Decodable { var login: String }
    struct Page: Decodable {
        struct PageInfo: Decodable { var hasNextPage: Bool; var endCursor: String? }
        var issueCount: Int
        var pageInfo: PageInfo
        var nodes: [Lossy<SummaryNode>]
    }

    var viewerLogin: String
    var rateLimit: RateLimitInfo?
    var searches: [String: SearchPage]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        viewerLogin = try container.decode(Viewer.self, forKey: Key(stringValue: "viewer")).login
        rateLimit = try container.decodeIfPresent(RateLimitInfo.self, forKey: Key(stringValue: "rateLimit"))
        var searches: [String: SearchPage] = [:]
        for key in container.allKeys where key.stringValue.hasPrefix("s") {
            guard let page = try container.decodeIfPresent(Page.self, forKey: key) else { continue }
            searches[key.stringValue] = SearchPage(
                issueCount: page.issueCount,
                hasNextPage: page.pageInfo.hasNextPage,
                endCursor: page.pageInfo.endCursor,
                nodes: page.nodes.compactMap { $0.value?.summary }
            )
        }
        self.searches = searches
    }
}

/// Decodes a search node, or `nil` for `null` and for the empty object GitHub returns when a hit
/// is not a PullRequest. Any other decoding failure is rethrown so schema drift is not hidden.
struct Lossy<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: any Decoder) throws {
        do {
            value = try T(from: decoder)
        } catch {
            if let single = try? decoder.singleValueContainer(), single.decodeNil() {
                value = nil
            } else if let keyed = try? decoder.container(keyedBy: DiscoveryData.Key.self), keyed.allKeys.isEmpty {
                value = nil
            } else {
                throw error
            }
        }
    }
}
