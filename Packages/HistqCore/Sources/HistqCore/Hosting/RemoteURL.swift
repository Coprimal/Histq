// A git remote URL split into the host it reaches and the path that names the repository. The host decides where a
// token goes, so it is the strict `HostingHTTP.validatedHost` form; the userinfo only identifies, it is never kept.
import Foundation

/// The host and path of `https://[user@]host[:port]/path`, `ssh://[user@]host[:port]/path` (also `git+ssh://`,
/// `ssh+git://`) and the scp-like `[user@]host:path` (a colon before any slash, as in
/// `HostKeyTrust.host(fromRemoteURL:)`). An https URL keeps its port (it is the API's port too); an ssh port is
/// dropped. The userinfo is everything before the last `@` of the authority (the host ssh and curl reach).
public struct RemoteURL: Sendable, Equatable {
    /// Lowercase, from `HostingHTTP.validatedHost(_:)`.
    public var host: String
    /// The percent-decoded path segments, without a trailing `/` or `.git`: never empty, `.`, `..` or holding `/`.
    public var segments: [String]
    /// A userinfo with a user name only (`git@`, `org@dev.azure.com`).
    public var hasUsername: Bool
    /// A userinfo with a password (`user:token@`), which a remote URL should not carry.
    public var hasPassword: Bool

    /// nil for other schemes, local paths, a host `validatedHost` refuses, an empty path, and an empty, `.`, `..`
    /// or undecodable segment.
    public init?(_ url: String) {
        let lower = url.lowercased()
        var authority: Substring
        var path: Substring
        var keepsPort = false
        if let scheme = ["https://", "ssh://", "git+ssh://", "ssh+git://"].first(where: { lower.hasPrefix($0) }) {
            let rest = url.dropFirst(scheme.count)
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            authority = rest[..<slash]
            path = rest[rest.index(after: slash)...]
            keepsPort = scheme == "https://"
        } else {
            guard !url.contains("://"), let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/") else {
                return nil
            }
            authority = url[..<colon]
            path = url[url.index(after: colon)...]
            if path.hasPrefix("/") { path = path.dropFirst() }
        }
        var userinfo: Substring?
        if let at = authority.lastIndex(of: "@") {
            userinfo = authority[..<at]
            authority = authority[authority.index(after: at)...]
        }
        if !keepsPort, let colon = authority.firstIndex(of: ":") { authority = authority[..<colon] }
        guard let host = HostingHTTP.validatedHost(String(authority)) else { return nil }

        while path.hasSuffix("/") { path = path.dropLast() }
        if path.lowercased().hasSuffix(".git") { path = path.dropLast(4) }
        var segments: [String] = []
        for raw in path.split(separator: "/", omittingEmptySubsequences: false) {
            guard let segment = raw.removingPercentEncoding, !segment.isEmpty, segment != ".", segment != "..",
                !segment.contains("/")
            else { return nil }
            segments.append(segment)
        }
        self.host = host
        self.segments = segments
        hasPassword = userinfo?.contains(":") ?? false
        hasUsername = userinfo.map { !$0.isEmpty && !$0.contains(":") } ?? false
    }
}
