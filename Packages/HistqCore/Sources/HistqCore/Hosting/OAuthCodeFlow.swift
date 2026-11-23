// The OAuth authorization code grant (RFC 6749 section 4.1) with a loopback redirect (RFC 8252 section 7.3), for hosts
// without a device flow (Bitbucket Cloud). `start()` makes the authorize URL with a fresh random `state` (and, for a host
// that takes it, a PKCE S256 challenge, RFC 7636); the app opens it in the browser and listens on the redirect URI's
// loopback port; `code(fromCallback:for:)` reads the callback's request target and refuses another path and a missing,
// repeated or wrong `state`; `exchange(_:for:)` trades the code at the token endpoint, and `refresh(_:)` a refresh
// token (rotated on each use by Bitbucket) for new tokens, as `OAuthRefresher.Refresh` wants. Requests go only to the
// token endpoint (https; a redirect off its origin or path is not followed). A confidential client's secret (Bitbucket
// requires one) is passed in by the app, kept in memory, sent only in the token requests' `Authorization: Basic`
// header, and never shown by a description or an error, even when a server repeats it.
import CryptoKit
import Foundation

public struct OAuthCodeFlow: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// One sign-in: open `url`, then give its callback to `code(fromCallback:for:)` and the code to `exchange(_:for:)`.
    /// Its descriptions show only the authorize host.
    public struct Attempt: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        /// The authorize URL to open in the browser.
        public let url: URL
        let state: String
        /// The PKCE verifier, nil without PKCE.
        let codeVerifier: String?

        public var description: String { "OAuthCodeFlow.Attempt(\(url.host() ?? ""))" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: ["host": url.host() as Any]) }
    }

    public enum CodeFlowError: Error, Equatable, Sendable, CustomStringConvertible {
        /// No OAuth client ID, or an empty client secret.
        case missingClient
        /// A request on the redirect path that is not this sign-in's answer: a missing, repeated or wrong `state`, or
        /// no usable `code`.
        case invalidCallback
        /// The user declined on the host.
        case accessDenied
        /// Any other OAuth error code, from the callback or the token endpoint.
        case failed(code: String, description: String?)

        /// The Bitbucket wording; `message(provider:)` names another host.
        public var description: String { message(provider: "Bitbucket") }

        /// The user-facing text, naming the host's product (`provider`: "Bitbucket").
        public func message(provider: String) -> String {
            switch self {
            case .missingClient: "No \(provider) OAuth client ID or secret is set."
            case .invalidCallback: "The browser's answer did not come from this sign-in. Start again."
            case .accessDenied: "The authorization was cancelled on \(provider)."
            case .failed(let code, let description):
                "\(provider) sign-in failed (\(code))" + (description.map { ": \($0)" } ?? ".")
            }
        }
    }

    /// The callback URL registered on Histq's Bitbucket OAuth client.
    public static let bitbucketRedirectURI = URL(string: "http://127.0.0.1:47823/callback")!

    public let authorizeEndpoint: URL
    public let tokenEndpoint: URL
    public let clientID: String
    /// The loopback URL the host sends the browser back to, exactly as registered.
    public let redirectURI: URL
    /// Sent as `scope` when not empty (Bitbucket takes the scopes from the client's settings).
    public let scopes: [String]
    public let usesPKCE: Bool
    private let clientSecret: String?
    private let session: URLSession

    /// Throws `CodeFlowError.missingClient` for an empty client ID or secret, `HostingError.invalidHost` for an
    /// endpoint that is not https on a valid host (or has userinfo, a query or a fragment), or a redirect URI that is
    /// not `http://127.0.0.1:<port>/<path>`.
    public init(
        authorizeEndpoint: URL, tokenEndpoint: URL, clientID: String, clientSecret: String? = nil, redirectURI: URL,
        scopes: [String] = [], usesPKCE: Bool = false, session: URLSession = HostingHTTP.session
    ) throws {
        for endpoint in [authorizeEndpoint, tokenEndpoint] {
            guard endpoint.scheme == "https", let host = endpoint.host(),
                  HostingHTTP.validatedHost(host + (endpoint.port.map { ":\($0)" } ?? "")) != nil,
                  endpoint.user() == nil, endpoint.password() == nil, endpoint.query() == nil, endpoint.fragment() == nil
            else { throw HostingError.invalidHost(endpoint.absoluteString) }
        }
        guard redirectURI.scheme == "http", redirectURI.host() == "127.0.0.1", redirectURI.port != nil,
              redirectURI.path().hasPrefix("/"), redirectURI.user() == nil, redirectURI.query() == nil,
              redirectURI.fragment() == nil
        else { throw HostingError.invalidHost(redirectURI.absoluteString) }
        guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              clientSecret.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true
        else { throw CodeFlowError.missingClient }
        self.authorizeEndpoint = authorizeEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.usesPKCE = usesPKCE
        self.session = session
    }

    /// Histq's Bitbucket Cloud OAuth client (Workspace settings › OAuth clients): authorize
    /// `https://bitbucket.org/site/oauth2/authorize`, token `https://bitbucket.org/site/oauth2/access_token` with the
    /// secret as HTTP Basic client authentication, redirect `bitbucketRedirectURI`. No PKCE: Atlassian's Bitbucket Cloud
    /// REST docs describe the grant without it, and do not say whether the token endpoint accepts or ignores it.
    public static func bitbucketCloud(
        clientID: String, clientSecret: String, session: URLSession = HostingHTTP.session
    ) throws -> OAuthCodeFlow {
        try OAuthCodeFlow(
            authorizeEndpoint: URL(string: "https://bitbucket.org/site/oauth2/authorize")!,
            tokenEndpoint: URL(string: "https://bitbucket.org/site/oauth2/access_token")!,
            clientID: clientID, clientSecret: clientSecret, redirectURI: bitbucketRedirectURI, session: session)
    }

    public var description: String { "OAuthCodeFlow(\(tokenEndpoint.host() ?? ""))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["tokenEndpoint": tokenEndpoint]) }

    /// A new sign-in: the authorize URL with `client_id`, `response_type=code`, `redirect_uri`, a fresh `state` (and
    /// `scope`, and the PKCE challenge, when set).
    public func start() -> Attempt {
        let state = Self.randomToken()
        let verifier = usesPKCE ? Self.randomToken() : nil
        var query = [
            "client_id": clientID, "response_type": "code", "redirect_uri": redirectURI.absoluteString, "state": state,
        ]
        if !scopes.isEmpty { query["scope"] = scopes.joined(separator: " ") }
        if let verifier {
            query["code_challenge"] = Self.challenge(verifier)
            query["code_challenge_method"] = "S256"
        }
        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = DeviceFlow.formEncoded(query)
        return Attempt(url: components.url!, state: state, codeVerifier: verifier)
    }

    /// The code of the callback `target` (the request target of the loopback request, `/callback?code=…&state=…`).
    /// Throws `CodeFlowError.invalidCallback` for another path, a missing, repeated or wrong `state`, or no usable
    /// code; `.accessDenied` or `.failed` for an OAuth error that carries the right `state`.
    public func code(fromCallback target: String, for attempt: Attempt) throws -> String {
        guard let components = URLComponents(string: target), components.scheme == nil, components.host == nil,
              components.percentEncodedPath == redirectURI.path(percentEncoded: true)
        else { throw CodeFlowError.invalidCallback }
        let items = components.queryItems ?? []
        /// The value of the one item `name`; nil when it is missing or repeated.
        func value(_ name: String) -> String? {
            let values = items.filter { $0.name == name }
            return values.count == 1 ? values[0].value : nil
        }
        guard let state = value("state"), state == attempt.state else { throw CodeFlowError.invalidCallback }
        if let error = value("error") {
            throw error == "access_denied"
                ? CodeFlowError.accessDenied : CodeFlowError.failed(code: error, description: value("error_description"))
        }
        guard let code = value("code"), HostingHTTP.isUsableToken(code) else { throw CodeFlowError.invalidCallback }
        return code
    }

    /// Trades the callback's `code` for tokens (`grant_type=authorization_code`, the same `redirect_uri`, the PKCE
    /// verifier when set). Throws `CodeFlowError.failed` for an OAuth error, else a `HostingError`.
    public func exchange(_ code: String, for attempt: Attempt) async throws -> DeviceFlow.Token {
        var form = ["grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI.absoluteString]
        if let verifier = attempt.codeVerifier { form["code_verifier"] = verifier }
        return try await tokenRequest(form, isRefresh: false)
    }

    /// New tokens for `refreshToken` (`grant_type=refresh_token`). A rejected grant throws as `OAuthRefresher.Refresh`
    /// says: `HostingError.unauthorized` for a 401, `HostingError.http(status: 400, _)` for a 400 or an OAuth error in
    /// a 200 answer; any other failure is another `HostingError`.
    public func refresh(_ refreshToken: String) async throws -> DeviceFlow.Token {
        try await tokenRequest(["grant_type": "refresh_token", "refresh_token": refreshToken], isRefresh: true)
    }

    /// The token endpoint's answer.
    private struct Answer: Decodable {
        var accessToken: String?
        var refreshToken: String?
        var expiresIn: Int?
        var error: String?
        var errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case error
            case errorDescription = "error_description"
        }
    }

    /// A form POST to the token endpoint, the client authenticated with HTTP Basic when it has a secret, else by
    /// `client_id` in the form.
    private func tokenRequest(_ form: [String: String], isRefresh: Bool) async throws -> DeviceFlow.Token {
        var form = form
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Histq", forHTTPHeaderField: "User-Agent")
        if let basicCredentials {
            request.setValue("Basic \(basicCredentials)", forHTTPHeaderField: "Authorization")
        } else {
            form["client_id"] = clientID
        }
        request.httpBody = Data(DeviceFlow.formEncoded(form).utf8)
        let (data, response) = try await HostingHTTP.load(
            request, session: session, allowedPathPrefix: tokenEndpoint.path(percentEncoded: true))
        let answer = try? HostingHTTP.decode(data) as Answer
        guard (200..<300).contains(response.statusCode) else {
            if !isRefresh, let code = answer?.error {
                throw scrubbed(CodeFlowError.failed(code: code, description: answer?.errorDescription), status: 400)
            }
            throw scrubbed(HostingHTTP.error(for: response, data: data), status: response.statusCode)
        }
        guard let answer else { throw HostingError.invalidResponse("unexpected JSON for the token") }
        guard let token = answer.accessToken else {
            guard let code = answer.error else { throw HostingError.invalidResponse("neither a token nor an error") }
            throw scrubbed(isRefresh ? HostingError.http(status: 400, message: code)
                : CodeFlowError.failed(code: code, description: answer.errorDescription), status: 400)
        }
        guard HostingHTTP.isUsableToken(token), answer.refreshToken.map(HostingHTTP.isUsableToken) ?? true
        else { throw HostingError.invalidResponse("an unusable token") }
        return DeviceFlow.Token(accessToken: token, refreshToken: answer.refreshToken, expiresIn: answer.expiresIn)
    }

    /// `client_id:secret` in base64, nil without a secret.
    private var basicCredentials: String? {
        clientSecret.map { Data("\(clientID):\($0)".utf8).base64EncodedString() }
    }

    /// `error`, or the bare `status` without the server's text when that text holds the secret or the Basic
    /// credentials (a server could echo them back).
    private func scrubbed(_ error: any Error, status: Int) -> any Error {
        guard let clientSecret, let basicCredentials else { return error }
        let text = String(describing: error)
        guard text.contains(clientSecret) || text.contains(basicCredentials) else { return error }
        return status == 401 ? HostingError.unauthorized : HostingError.http(status: status, message: "")
    }

    /// 32 bytes from the system's cryptographically secure generator (`arc4random_buf` on Apple platforms), base64url
    /// without padding: 43 URL-safe characters, also a valid PKCE verifier.
    private static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<4).flatMap { _ in withUnsafeBytes(of: generator.next() as UInt64) { Array($0) } }
        return base64URL(Data(bytes))
    }

    /// The PKCE S256 challenge of `verifier`: base64url(SHA-256(verifier)) without padding.
    private static func challenge(_ verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacing("+", with: "-").replacing("/", with: "_").replacing("=", with: "")
    }
}
