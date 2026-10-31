import Foundation

public struct SearchRequest: Sendable, Hashable {
    public var query: String
    public var after: String?

    public init(query: String, after: String? = nil) {
        self.query = query
        self.after = after
    }
}

public struct SearchPage: Sendable, Hashable {
    public var issueCount: Int
    public var hasNextPage: Bool
    public var endCursor: String?
    public var nodes: [PRSummary]

    public init(issueCount: Int, hasNextPage: Bool, endCursor: String?, nodes: [PRSummary]) {
        self.issueCount = issueCount
        self.hasNextPage = hasNextPage
        self.endCursor = endCursor
        self.nodes = nodes
    }
}

public struct DiscoveryResult: Sendable {
    public var viewerLogin: String
    public var rateLimit: RateLimitInfo?
    /// One page per request, in request order.
    public var pages: [SearchPage]
    /// Some organizations withheld results until the token is authorized for SAML SSO.
    public var ssoPartial: Bool

    public init(viewerLogin: String, rateLimit: RateLimitInfo?, pages: [SearchPage], ssoPartial: Bool = false) {
        self.viewerLogin = viewerLogin
        self.rateLimit = rateLimit
        self.pages = pages
        self.ssoPartial = ssoPartial
    }
}

public struct DetailResult: Sendable {
    public var pullRequests: [PullRequest]
    public var rateLimit: RateLimitInfo?

    public init(pullRequests: [PullRequest], rateLimit: RateLimitInfo?) {
        self.pullRequests = pullRequests
        self.rateLimit = rateLimit
    }
}

public enum GitHubError: Error, Sendable, Equatable {
    case missingToken
    /// HTTP 401: token revoked or expired.
    case unauthorized
    /// The organization requires SAML SSO authorization for this token.
    case ssoRequired(URL?)
    case rateLimited(until: Date?)
    /// 5xx, including GitHub's query timeouts (502).
    case server(status: Int)
    case http(status: Int)
    /// GraphQL errors with no usable data. Messages only; never response bodies.
    case graphQL([String])
    case transport(String)
    case decoding(String)
}

public protocol GitHubClient: Sendable {
    /// Validates the token and returns the signed-in login and classic scopes.
    func viewer() async throws -> TokenInfo
    /// Runs several searches in one request. Pages are returned in request order.
    func discover(_ requests: [SearchRequest]) async throws -> DiscoveryResult
    /// Full detail for up to about 10 PRs. Deleted or inaccessible IDs are omitted.
    func pullRequests(ids: [String]) async throws -> DetailResult
    /// `org/slug` for every team `login` belongs to, across the viewer's organizations.
    func teams(login: String) async throws -> Set<String>
}
