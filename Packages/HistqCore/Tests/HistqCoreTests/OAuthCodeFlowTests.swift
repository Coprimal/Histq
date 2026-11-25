// Security tests of the OAuth authorization code flow, served by `StubServer` (GitHubClientTests.swift): no test reaches
// the network. They guard the callback (only this sign-in's `state`, only the redirect path), the token requests (only
// to the token endpoint, the secret only in the Basic header, a redirect elsewhere not followed), the PKCE pair, and
// that no error or description ever holds the client secret, even when the server repeats it.
import CryptoKit
import Foundation
import HistqCore
import Synchronization
import Testing

struct OAuthCodeFlowTests {
    /// Made-up client credentials and tokens; the tests look for the secret where it must never be.
    static let clientID = "histq-fake-client-id"
    static let secret = "histq-fake-secret-0123456789"
    static let basic = Data("\(clientID):\(secret)".utf8).base64EncodedString()
    static let tokens = #"{"access_token": "histq-fake-access", "refresh_token": "histq-fake-refresh-2", "#
        + #""expires_in": 7200, "token_type": "bearer", "scope": "account repository"}"#

    static func bitbucket(_ stub: StubServer) throws -> OAuthCodeFlow {
        try OAuthCodeFlow.bitbucketCloud(clientID: clientID, clientSecret: secret, session: stub.session)
    }

    static func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    static func form(_ request: URLRequest?) -> [String: String] {
        let body = String(decoding: request?.httpBody ?? Data(), as: UTF8.self)
        return Dictionary(body.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
            return (parts[0], parts.count > 1 ? parts[1] : "")
        }, uniquingKeysWith: { first, _ in first })
    }

    @Test("the authorize URL is Bitbucket's, with the registered redirect URI and a fresh URL-safe state, without PKCE")
    func authorizeURL() throws {
        let flow = try Self.bitbucket(StubServer { _ in .init(body: "{}") })
        let first = flow.start()
        let second = flow.start()

        #expect(first.url.absoluteString.hasPrefix("https://bitbucket.org/site/oauth2/authorize?"))
        let query = Self.query(first.url)
        #expect(query["client_id"] == Self.clientID)
        #expect(query["response_type"] == "code")
        #expect(query["redirect_uri"] == "http://127.0.0.1:47823/callback")
        let state = try #require(query["state"])
        #expect(state.count == 43)
        #expect(state.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0) })
        #expect(Self.query(second.url)["state"] != state, "a new state for each sign-in")
        #expect(query["code_challenge"] == nil && query["code_challenge_method"] == nil)
        #expect(query["client_secret"] == nil)
    }

    @Test("a callback with a missing, repeated or wrong state, on another path, or without a code is rejected")
    func callbackRejected() throws {
        let flow = try Self.bitbucket(StubServer { _ in .init(body: "{}") })
        let attempt = flow.start()
        let state = try #require(Self.query(attempt.url)["state"])
        let other = flow.start()
        let otherState = try #require(Self.query(other.url)["state"])

        for target in [
            "/callback?code=abc",
            "/callback?code=abc&state=",
            "/callback?code=abc&state=\(otherState)",
            "/callback?code=abc&state=\(state)x",
            "/callback?code=abc&state=\(state)&state=\(otherState)",
            "/callback?code=abc&state=\(otherState)&state=\(state)",
            "/callback/?code=abc&state=\(state)",
            "/other?code=abc&state=\(state)",
            "/callbackx?code=abc&state=\(state)",
            "//evil.example/callback?code=abc&state=\(state)",
            "http://127.0.0.1:47823/callback?code=abc&state=\(state)",
            "/callback?state=\(state)",
            "/callback?code=&state=\(state)",
            "/callback?code=a%20b&state=\(state)",
            "/callback?error=access_denied&state=\(otherState)",
            "/callback?error=access_denied",
        ] {
            #expect(throws: OAuthCodeFlow.CodeFlowError.invalidCallback, "\(target)") {
                try flow.code(fromCallback: target, for: attempt)
            }
        }
        #expect(try flow.code(fromCallback: "/callback?code=abc123&state=\(state)", for: attempt) == "abc123")
        #expect(throws: OAuthCodeFlow.CodeFlowError.accessDenied) {
            try flow.code(fromCallback: "/callback?error=access_denied&state=\(state)", for: attempt)
        }
    }

    @Test("the code exchange goes only to the token endpoint, the secret only in the Basic header")
    func exchangeOnlyToTokenEndpoint() async throws {
        let stub = StubServer { _ in .init(body: Self.tokens) }
        let flow = try Self.bitbucket(stub)
        let attempt = flow.start()

        let token = try await flow.exchange("the-code", for: attempt)

        #expect(token == DeviceFlow.Token(
            accessToken: "histq-fake-access", refreshToken: "histq-fake-refresh-2", expiresIn: 7200))
        let requests = stub.requests
        #expect(requests.count == 1)
        #expect(requests.allSatisfy { $0.url?.absoluteString == "https://bitbucket.org/site/oauth2/access_token" })
        let request = requests.first
        #expect(request?.httpMethod == "POST")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Basic \(Self.basic)")
        #expect(Self.form(request) == [
            "grant_type": "authorization_code", "code": "the-code", "redirect_uri": "http://127.0.0.1:47823/callback",
        ])
        let body = String(decoding: request?.httpBody ?? Data(), as: UTF8.self)
        let secretInBody = body.contains(Self.secret)
        #expect(!secretInBody)
    }

    @Test("a token request redirected to another host is not followed")
    func redirectNotFollowed() async throws {
        let stub = StubServer { request in
            request.url?.host() == "bitbucket.org"
                ? .init(status: 302, body: "", redirect: URL(string: "https://evil.example/site/oauth2/access_token"))
                : .init(body: Self.tokens)
        }
        let flow = try Self.bitbucket(stub)

        await #expect(throws: HostingError.self) { try await flow.exchange("the-code", for: flow.start()) }
        await #expect(throws: HostingError.self) { try await flow.refresh("histq-fake-refresh") }
        #expect(stub.requests.allSatisfy { $0.url?.host() == "bitbucket.org" })
    }

    @Test("a refresh sends the refresh token; a rejection throws as the refresher expects")
    func refresh() async throws {
        let answers = Mutex([
            (200, Self.tokens),
            (400, #"{"error": "invalid_grant", "error_description": "Invalid refresh_token"}"#),
            (401, #"{"error": "invalid_client"}"#),
            (200, #"{"error": "invalid_grant"}"#),
        ])
        let stub = StubServer { _ in
            let (status, body) = answers.withLock { $0.removeFirst() }
            return .init(status: status, body: body)
        }
        let flow = try Self.bitbucket(stub)

        let token = try await flow.refresh("histq-fake-refresh")
        #expect(token.refreshToken == "histq-fake-refresh-2")
        #expect(Self.form(stub.requests.first) == ["grant_type": "refresh_token", "refresh_token": "histq-fake-refresh"])
        await #expect(throws: HostingError.http(status: 400, message: "Invalid refresh_token")) {
            try await flow.refresh("histq-fake-refresh")
        }
        await #expect(throws: HostingError.unauthorized) { try await flow.refresh("histq-fake-refresh") }
        await #expect(throws: HostingError.http(status: 400, message: "invalid_grant")) {
            try await flow.refresh("histq-fake-refresh")
        }
    }

    @Test("the client secret never appears in an error or a description, even when the server repeats it",
          arguments: [400, 401, 403, 500, 200])
    func secretNeverShown(status: Int) async throws {
        let stub = StubServer { request in
            let header = request.value(forHTTPHeaderField: "Authorization") ?? ""
            let echo = "\(header) \(OAuthCodeFlowTests.secret)"
            return .init(status: status, body: #"{"error": "\#(echo)", "error_description": "\#(echo)", "#
                + #""message": "\#(echo)"}"#)
        }
        let flow = try Self.bitbucket(stub)
        let attempt = flow.start()
        var texts = [String(describing: flow), String(reflecting: flow), String(describing: attempt),
                     String(reflecting: attempt)]
        var dumped = ""
        dump(flow, to: &dumped)
        texts.append(dumped)
        for request in [{ _ = try await flow.exchange("the-code", for: attempt) },
                        { _ = try await flow.refresh("histq-fake-refresh") }] {
            do {
                try await request()
                Issue.record("an echoed error was taken as tokens")
            } catch {
                texts += [String(describing: error), String(reflecting: error), error.localizedDescription]
                if let error = error as? OAuthCodeFlow.CodeFlowError { texts.append(error.message(provider: "Bitbucket")) }
            }
        }
        let leaked = texts.contains { $0.contains(Self.secret) || $0.contains(Self.basic) }
        #expect(!leaked)
    }

    @Test("with PKCE the verifier sent with the code matches the S256 challenge of the authorize URL")
    func pkce() async throws {
        let stub = StubServer { _ in .init(body: Self.tokens) }
        let flow = try OAuthCodeFlow(
            authorizeEndpoint: URL(string: "https://login.example.test/authorize")!,
            tokenEndpoint: URL(string: "https://login.example.test/token")!, clientID: Self.clientID,
            redirectURI: URL(string: "http://127.0.0.1:50000/callback")!, scopes: ["a", "b"], usesPKCE: true,
            session: stub.session)
        let attempt = flow.start()
        let query = Self.query(attempt.url)
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["scope"] == "a b")

        _ = try await flow.exchange("the-code", for: attempt)

        let form = Self.form(stub.requests.first)
        let verifier = try #require(form["code_verifier"])
        #expect((43...128).contains(verifier.count))
        let digest = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacing("+", with: "-").replacing("/", with: "_").replacing("=", with: "")
        #expect(query["code_challenge"] == digest)
        #expect(form["client_id"] == Self.clientID, "a public client names itself in the form")
        #expect(stub.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Azure DevOps signs in with Entra as a public client: PKCE, scope, a localhost redirect without a path")
    func azureDevOps() async throws {
        let stub = StubServer { _ in .init(body: Self.tokens) }
        let flow = try OAuthCodeFlow.azureDevOps(clientID: Self.clientID, port: 50123, session: stub.session)
        let attempt = flow.start()
        let query = Self.query(attempt.url)
        let scope = "499b84ac-1321-427f-aa17-267ca6975798/.default offline_access"
        let token = "https://login.microsoftonline.com/organizations/oauth2/v2.0/token"

        #expect(attempt.url.absoluteString.hasPrefix(
            "https://login.microsoftonline.com/organizations/oauth2/v2.0/authorize?"))
        #expect(query["client_id"] == Self.clientID)
        #expect(query["redirect_uri"] == "http://localhost:50123")
        #expect(query["scope"] == scope)
        #expect(query["code_challenge_method"] == "S256")
        #expect(flow.callbackPath == "/")
        let state = try #require(query["state"])
        #expect(try flow.code(fromCallback: "/?code=abc123&state=\(state)", for: attempt) == "abc123")

        _ = try await flow.exchange("the-code", for: attempt)
        _ = try await flow.refresh("histq-fake-refresh")

        let requests = stub.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy {
            $0.url?.absoluteString == token && $0.value(forHTTPHeaderField: "Authorization") == nil
        })
        let exchange = Self.form(requests.first)
        #expect(exchange["grant_type"] == "authorization_code")
        #expect(exchange["redirect_uri"] == "http://localhost:50123")
        #expect(exchange["client_id"] == Self.clientID)
        #expect(exchange["code_verifier"] != nil)
        #expect(Self.form(requests.last) == [
            "grant_type": "refresh_token", "refresh_token": "histq-fake-refresh", "client_id": Self.clientID,
            "scope": scope,
        ])
        #expect(throws: OAuthCodeFlow.CodeFlowError.missingClient) {
            try OAuthCodeFlow.azureDevOps(clientID: " ")
        }
    }

    @Test("endpoints must be https without userinfo, the redirect a 127.0.0.1 port, the client complete")
    func refusedSetups() {
        let https = URL(string: "https://example.test/token")!
        let loopback = URL(string: "http://127.0.0.1:47823/callback")!
        func make(_ authorize: URL = https, _ token: URL = https, _ redirect: URL = loopback, secret: String? = "s",
                  id: String = "id") throws {
            _ = try OAuthCodeFlow(
                authorizeEndpoint: authorize, tokenEndpoint: token, clientID: id, clientSecret: secret,
                redirectURI: redirect)
        }
        for url in ["http://example.test/token", "https://user@example.test/token", "https://example.test/t?x=1"] {
            #expect(throws: HostingError.self, "\(url)") { try make(https, URL(string: url)!) }
            #expect(throws: HostingError.self, "\(url)") { try make(URL(string: url)!) }
        }
        for url in ["http://0.0.0.0:47823/callback", "http://localhost:47823/callback", "https://127.0.0.1:47823/callback",
                    "http://127.0.0.1/callback", "http://evil.example:47823/callback"] {
            #expect(throws: HostingError.self, "\(url)") { try make(https, https, URL(string: url)!) }
        }
        #expect(throws: OAuthCodeFlow.CodeFlowError.missingClient) { try make(secret: " ") }
        #expect(throws: OAuthCodeFlow.CodeFlowError.missingClient) { try make(id: "") }
        #expect(throws: OAuthCodeFlow.CodeFlowError.missingClient) {
            try OAuthCodeFlow.bitbucketCloud(clientID: Self.clientID, clientSecret: "")
        }
    }
}
