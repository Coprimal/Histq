import Foundation

/// What the client and the device flow share: loading with the redirect guard, status mapping, JSON, `Link`,
/// and the host and token checks.
public enum HostingHTTP {
    /// `allowedPathPrefix` (a percent-encoded path such as `/gitlab/api/v4`) also refuses a same-origin redirect
    /// whose path is not under it, so a host under a relative root never sends the token elsewhere on its origin.
    static func load(_ request: URLRequest, session: URLSession, allowedPathPrefix: String? = nil) async throws
        -> (Data, HTTPURLResponse)
    {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(
                for: request, delegate: SameOriginRedirects(allowedPathPrefix: allowedPathPrefix))
        } catch let error as URLError {
            // The code only: `localizedDescription` can carry the failing URL, which is never a secret here, but
            // a short code is all the UI needs.
            throw HostingError.transport("URL error \(error.code.rawValue)")
        }
        guard let http = response as? HTTPURLResponse else { throw HostingError.invalidResponse("not HTTP") }
        return (data, http)
    }

    static func decode<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw HostingError.invalidResponse("unexpected JSON for \(T.self)")
        }
    }

    /// 401 is auth; a 403 or 429 is the primary rate limit with `X-RateLimit-Remaining: 0`, a secondary one with
    /// `Retry-After`, a 429 or GitHub's "secondary rate limit" message, and otherwise a plain refusal.
    static func error(for response: HTTPURLResponse, data: Data) -> HostingError {
        struct Body: Decodable { var message: String? }
        let text = (try? JSONDecoder().decode(Body.self, from: data))?.message ?? otherMessage(data)
        let message = String(text.prefix(500))
        let status = response.statusCode
        switch status {
        case 401:
            return .unauthorized
        case 403, 429:
            if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init)
                return .rateLimited(resetsAt: reset.map { Date(timeIntervalSince1970: $0) })
            }
            if let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap({ Int($0) }) {
                return .secondaryRateLimited(retryAfterSeconds: retry)
            }
            if status == 429 || message.localizedCaseInsensitiveContains("secondary rate limit") {
                return .secondaryRateLimited(retryAfterSeconds: nil)
            }
            return .forbidden(message: message)
        case 404:
            return .notFound
        case 422:
            return .validationFailed(message: message)
        default:
            return .http(status: status, message: message)
        }
    }

    /// The message of an error body whose `message` is not a string (GitLab): an object's fields as `field: msg1,
    /// msg2` (sorted, joined by `; `), an array's strings, else `error_description`, `error`, or the `message` of an
    /// `error` object (Bitbucket); empty otherwise.
    private static func otherMessage(_ data: Data) -> String {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        func text(_ value: Any) -> String? {
            if let string = value as? String { return string }
            if let array = value as? [Any] { return array.compactMap { $0 as? String }.joined(separator: ", ") }
            return nil
        }
        if let fields = body["message"] as? [String: Any] {
            return fields.sorted { $0.key < $1.key }
                .compactMap { field in text(field.value).map { "\(field.key): \($0)" } }
                .joined(separator: "; ")
        }
        if let message = body["message"].flatMap(text) { return message }
        if let error = body["error"] as? [String: Any], let message = error["message"] as? String { return message }
        return (body["error_description"] as? String) ?? (body["error"] as? String) ?? ""
    }

    /// The `rel="next"` URL of a `Link` header (`<url>; rel="next", <url>; rel="last"`).
    static func nextLink(_ header: String?) -> URL? {
        guard let header else { return nil }
        for part in header.split(separator: ",") {
            let fields = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let target = fields.first, target.hasPrefix("<"), target.hasSuffix(">") else { continue }
            let isNext = fields.dropFirst().contains { field in
                let pair = field.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard pair.count == 2, pair[0].lowercased() == "rel" else { return false }
                return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    .split(separator: " ").contains("next")
            }
            if isNext { return URL(string: String(target.dropFirst().dropLast())) }
        }
        return nil
    }

    /// `host` lowercased when it is a DNS name (letters, digits, `.`, `-`, `_`, not starting with `.` or `-`)
    /// with an optional `:port`; nil otherwise. The strict set keeps it safe in a URL and in a git config key
    /// (`credential.https://<host>.helper`), where `*` would be a wildcard and `/` or `@` would change the URL.
    public static func validatedHost(_ host: String) -> String? {
        let parts = host.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let name = parts[0]
        let nameOK = !name.isEmpty && name.utf8.count <= 253 && !name.hasPrefix(".") && !name.hasPrefix("-")
            && name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
        guard nameOK else { return nil }
        if parts.count == 2 {
            guard parts[1].allSatisfy({ $0.isASCII && $0.isNumber }), let port = Int(parts[1]), (1...65535).contains(port) else {
                return nil
            }
        }
        return host.lowercased()
    }

    /// Printable ASCII without spaces or backslashes: a newline would end the HTTP header (or a credential helper's
    /// line), and an `echo` that expands backslashes could print `\n` as one. GitHub tokens have neither.
    public static func isUsableToken(_ token: String) -> Bool {
        !token.isEmpty && token.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) && $0 != "\\" }
    }

    static func isSameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() && a.host()?.lowercased() == b.host()?.lowercased()
            && a.port == b.port
    }

    /// Whether `url`'s path is `prefix` (percent-encoded) plus whole segments, none of them, nor any `/`-separated
    /// part of one percent-decoded, `.` or `..`, so `/api/v4evil`, `/api/v4/../x` or `/api/v4/..%2Fx` is not under
    /// `/api/v4` (an encoded project path such as `group%2Fproj` is).
    static func isPath(of url: URL, under prefix: String) -> Bool {
        let base = prefix.split(separator: "/", omittingEmptySubsequences: false)
        let path = url.path(percentEncoded: true).split(separator: "/", omittingEmptySubsequences: false)
        guard path.starts(with: base) else { return false }
        return !path.dropFirst(base.count).contains { segment in
            let decoded = segment.removingPercentEncoding ?? String(segment)
            return decoded.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == "." || $0 == ".." }
        }
    }
}

/// Refuses a redirect to another origin, or with `allowedPathPrefix` to a path outside it: URLSession would copy the
/// `Authorization` header to the new request. The 3xx answer then fails as an HTTP error.
private final class SameOriginRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    let allowedPathPrefix: String?

    init(allowedPathPrefix: String?) {
        self.allowedPathPrefix = allowedPathPrefix
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let from = task.originalRequest?.url, let to = request.url, HostingHTTP.isSameOrigin(from, to) else {
            return nil
        }
        if let allowedPathPrefix, !HostingHTTP.isPath(of: to, under: allowedPathPrefix) { return nil }
        return request
    }
}
