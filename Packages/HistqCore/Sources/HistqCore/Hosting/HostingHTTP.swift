import Foundation

/// What the client and the device flow share: loading with the redirect guard, status mapping, JSON, `Link`.
enum HostingHTTP {
    static func load(_ request: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: SameOriginRedirects())
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
        let message = String(((try? JSONDecoder().decode(Body.self, from: data))?.message ?? "").prefix(500))
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

    static func isSameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() && a.host()?.lowercased() == b.host()?.lowercased()
            && a.port == b.port
    }
}

/// Refuses a redirect to another origin: URLSession would copy the `Authorization` header to the new request.
/// The 3xx answer then fails as an HTTP error.
private final class SameOriginRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let from = task.originalRequest?.url, let to = request.url, HostingHTTP.isSameOrigin(from, to) else {
            return nil
        }
        return request
    }
}
