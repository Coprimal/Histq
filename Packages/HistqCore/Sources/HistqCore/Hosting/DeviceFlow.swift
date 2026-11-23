// The OAuth device flow (RFC 8628) of GitHub and GitLab: `start()` asks for a user code the user types at the
// verification URL, then `waitForToken(_:)` polls the token endpoint until the user approves. GitHub's endpoints are
// `https://<host>/login/device/code` and `https://<host>/login/oauth/access_token` (the web host, not the API host),
// GitLab's `https://<host>[/<basePath>]/oauth/authorize_device` and `.../oauth/token`. Both report the flow's states as
// `error` codes, GitHub in a 200 answer and GitLab (as RFC 8628 says) in a 400, read either way:
// `authorization_pending` (poll again), `slow_down` (wait 5 s longer from now on), `expired_token` and `access_denied`.
// The wait is an injected `sleep`, so tests never wait, and the time slept counts against the code's `expires_in` so a
// flow cannot poll forever. `refresh(_:)` trades a refresh token for new tokens at the same token endpoint. A GitLab
// request never follows a redirect off its origin or outside `<basePath>/oauth`.
import Foundation

public struct DeviceFlow: Sendable {
    /// What `start()` returns: show `userCode` and open `verificationURI`.
    public struct DeviceCode: Sendable, Equatable, Decodable {
        public var deviceCode: String
        public var userCode: String
        public var verificationURI: String
        /// `verificationURI` with the user code filled in, when the host sends it (GitLab).
        public var verificationURIComplete: String?
        /// Seconds until the codes expire.
        public var expiresIn: Int
        /// Seconds to wait between polls.
        public var interval: Int

        public init(
            deviceCode: String, userCode: String, verificationURI: String, verificationURIComplete: String? = nil,
            expiresIn: Int, interval: Int
        ) {
            self.deviceCode = deviceCode
            self.userCode = userCode
            self.verificationURI = verificationURI
            self.verificationURIComplete = verificationURIComplete
            self.expiresIn = expiresIn
            self.interval = interval
        }

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationURI = "verification_uri"
            case verificationURIComplete = "verification_uri_complete"
            case expiresIn = "expires_in"
            case interval
        }
    }

    /// What `waitForToken(_:)` returns. `refreshToken` and `expiresIn` are there only when the host sends them
    /// (GitLab's documented device grant has no refresh token). Its descriptions never show the tokens.
    public struct Token: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        public var accessToken: String
        public var refreshToken: String?
        /// Seconds until the access token expires.
        public var expiresIn: Int?

        public init(accessToken: String, refreshToken: String? = nil, expiresIn: Int? = nil) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresIn = expiresIn
        }

        public var description: String {
            let expiry = expiresIn.map(String.init) ?? "none"
            return "DeviceFlow.Token(refresh: \(refreshToken == nil ? "none" : "set"), expiresIn: \(expiry))"
        }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: ["expiresIn": expiresIn as Any]) }
    }

    public enum DeviceFlowError: Error, Equatable, Sendable, CustomStringConvertible {
        /// No OAuth client ID (`HistqGitHubClientID` or `HistqGitLabClientID` is empty).
        case missingClientID
        /// The user did not enter the code in time.
        case expired
        /// The user pressed Cancel on the host.
        case accessDenied
        /// Any other OAuth error code (`device_flow_disabled`, `incorrect_client_credentials`...).
        case failed(code: String, description: String?)

        /// The GitHub wording; `message(provider:)` names another host.
        public var description: String { message(provider: "GitHub") }

        /// The user-facing text, naming the host's product (`provider`: "GitHub", "GitLab").
        public func message(provider: String) -> String {
            switch self {
            case .missingClientID:
                provider == "GitHub" ? "No GitHub OAuth App client ID is set." : "No \(provider) application ID is set."
            case .expired: "The code expired before it was entered. Start again."
            case .accessDenied: "The authorization was cancelled on \(provider)."
            case .failed(let code, let description):
                "\(provider) sign-in failed (\(code))" + (description.map { ": \($0)" } ?? ".")
            }
        }
    }

    public let kind: HostingKind
    public let host: String
    /// GitLab's relative URL root as segments; always empty for GitHub.
    public let basePath: [String]
    public let clientID: String
    public let scopes: [String]
    private let webBase: URL
    private let session: URLSession
    private let sleep: @Sendable (Duration) async throws -> Void

    /// `scopes` (nil for the kind's own): on GitHub `repo` for private repositories and HTTPS pushes, `read:org` for
    /// organization repositories, `workflow` because GitHub refuses a push that changes `.github/workflows` without
    /// it; on GitLab `api`, `read_user`, `read_repository` and `write_repository`. `basePath` is GitLab's relative URL
    /// root (ignored for GitHub). Throws `HostingError.invalidHost` or `DeviceFlowError.missingClientID`.
    public init(
        kind: HostingKind = .github, host: String = "github.com", basePath: String? = nil, clientID: String,
        scopes: [String]? = nil, session: URLSession = HostingHTTP.session,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) throws {
        let segments = kind == .gitlab ? GitLabClient.basePathSegments(basePath) : []
        guard let validHost = HostingHTTP.validatedHost(host), let segments,
              let webBase = URL(string: "https://\(validHost)" + segments.map { "/" + $0 }.joined())
        else {
            throw HostingError.invalidHost(host)
        }
        guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeviceFlowError.missingClientID
        }
        self.kind = kind
        self.host = validHost
        self.basePath = segments
        self.clientID = clientID
        self.scopes = scopes ?? (kind == .github ? ["repo", "read:org", "workflow"]
            : ["api", "read_user", "read_repository", "write_repository"])
        self.webBase = webBase
        self.session = session
        self.sleep = sleep
    }

    /// Asks for a device code and a user code.
    public func start() async throws -> DeviceCode {
        let path = kind == .github ? ["login", "device", "code"] : ["oauth", "authorize_device"]
        let data = try await post(path, ["client_id": clientID, "scope": scopes.joined(separator: " ")])
        if let failure = try? HostingHTTP.decode(data) as Answer, let code = failure.error {
            throw DeviceFlowError.failed(code: code, description: failure.errorDescription)
        }
        return try HostingHTTP.decode(data)
    }

    /// Polls until the user approves and returns the tokens. Throws `DeviceFlowError.expired`, `.accessDenied` or
    /// `.failed`, a `HostingError` for an HTTP failure or an unusable token, or `CancellationError`.
    public func waitForToken(_ code: DeviceCode) async throws -> Token {
        let path = kind == .github ? ["login", "oauth", "access_token"] : ["oauth", "token"]
        var interval = max(code.interval, 1)
        var waited = 0
        while true {
            guard waited < code.expiresIn else { throw DeviceFlowError.expired }
            try await sleep(.seconds(interval))
            waited += interval
            try Task.checkCancellation()
            let data = try await post(path, [
                "client_id": clientID, "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ], errorIsAnswer: kind == .gitlab)
            let answer: Answer = try HostingHTTP.decode(data)
            if let token = answer.accessToken {
                guard HostingHTTP.isUsableToken(token), answer.refreshToken.map(HostingHTTP.isUsableToken) ?? true else {
                    throw HostingError.invalidResponse("an unusable token")
                }
                return Token(accessToken: token, refreshToken: answer.refreshToken, expiresIn: answer.expiresIn)
            }
            switch answer.error {
            case "authorization_pending":
                continue
            case "slow_down":
                // Every later poll waits 5 s longer; GitHub may also say the new interval itself.
                interval = max(interval + 5, answer.interval ?? 0)
            case "expired_token":
                throw DeviceFlowError.expired
            case "access_denied":
                throw DeviceFlowError.accessDenied
            case let code?:
                throw DeviceFlowError.failed(code: code, description: answer.errorDescription)
            case nil:
                throw HostingError.invalidResponse("neither a token nor an error")
            }
        }
    }

    /// A new access token for `refreshToken` (`grant_type=refresh_token`, RFC 6749 section 6) from the token endpoint.
    /// A rejected grant throws as `OAuthRefresher.Refresh` says: `HostingError.unauthorized` for a 401,
    /// `HostingError.http(status: 400, _)` for a 400 (`invalid_grant`) or an OAuth error in a 200 answer; any other
    /// failure is another `HostingError`.
    public func refresh(_ refreshToken: String) async throws -> Token {
        let path = kind == .github ? ["login", "oauth", "access_token"] : ["oauth", "token"]
        let data = try await post(path, [
            "client_id": clientID, "grant_type": "refresh_token", "refresh_token": refreshToken,
        ], oauthErrors: false)
        let answer: Answer = try HostingHTTP.decode(data)
        guard let token = answer.accessToken else {
            guard let code = answer.error else { throw HostingError.invalidResponse("neither a token nor an error") }
            throw HostingError.http(status: 400, message: code)
        }
        guard HostingHTTP.isUsableToken(token), answer.refreshToken.map(HostingHTTP.isUsableToken) ?? true
        else { throw HostingError.invalidResponse("an unusable token") }
        return Token(accessToken: token, refreshToken: answer.refreshToken, expiresIn: answer.expiresIn)
    }

    /// The token endpoint's answer: tokens, or an OAuth error code (with a new `interval` for `slow_down`).
    private struct Answer: Decodable {
        var accessToken: String?
        var refreshToken: String?
        var expiresIn: Int?
        var error: String?
        var errorDescription: String?
        var interval: Int?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case error
            case errorDescription = "error_description"
            case interval
        }
    }

    /// A form POST asking for JSON. An HTTP failure with an OAuth error code is returned as the answer when
    /// `errorIsAnswer` (GitLab's polls), else it throws `DeviceFlowError.failed`; one without, any HTTP failure
    /// without `oauthErrors` (a refresh), or a GitLab 404, becomes a `HostingError`. GitLab's requests refuse a redirect outside
    /// `<basePath>/oauth`.
    private func post(
        _ segments: [String], _ form: [String: String], errorIsAnswer: Bool = false, oauthErrors: Bool = true
    ) async throws -> Data {
        var url = webBase
        for segment in segments { url.append(path: segment) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Histq", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(Self.formEncoded(form).utf8)
        let prefix = kind == .gitlab ? webBase.appending(path: "oauth").path(percentEncoded: true) : nil
        let (data, response) = try await HostingHTTP.load(request, session: session, allowedPathPrefix: prefix)
        if !(200..<300).contains(response.statusCode) {
            // A GitLab without the endpoint (no device grant) may still send an `error` in its 404 body.
            guard oauthErrors, kind == .github || response.statusCode != 404 else {
                throw HostingHTTP.error(for: response, data: data)
            }
            let answer = try? HostingHTTP.decode(data) as Answer
            if errorIsAnswer, answer?.error != nil { return data }
            if let code = answer?.error { throw DeviceFlowError.failed(code: code, description: answer?.errorDescription) }
            throw HostingHTTP.error(for: response, data: data)
        }
        return data
    }

    /// `application/x-www-form-urlencoded` with only unreserved characters left as they are.
    static func formEncoded(_ form: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        return form.sorted { $0.key < $1.key }.map { "\(encode($0.key))=\(encode($0.value))" }.joined(separator: "&")
    }
}
