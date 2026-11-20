// Remote URL parsing. Security-relevant: the parsed host decides where a token goes, so a bent host must never
// parse, and the userinfo must never stand in for the host.
import HistqCore
import Testing

struct RemoteURLTests {
    /// What a URL parses to: host, segments, user name only, password.
    struct Parsed: Equatable, CustomStringConvertible {
        var host: String
        var segments: [String]
        var username = false
        var password = false

        var description: String { "\(host) \(segments) username: \(username) password: \(password)" }
    }

    @Test("remote URLs give their host and decoded path segments; bent hosts and paths give nothing", arguments: [
        // GitHub forms (also in GitHubClientTests).
        ("git@ghe.example.com:Team/app.git", Parsed(host: "ghe.example.com", segments: ["Team", "app"], username: true)),
        ("org-1@GHE.Example.com:/team/my.repo",
         Parsed(host: "ghe.example.com", segments: ["team", "my.repo"], username: true)),
        ("https://github.com/octo/hello.git", Parsed(host: "github.com", segments: ["octo", "hello"])),
        ("https://user@ghe.example.com:8443/team/app/",
         Parsed(host: "ghe.example.com:8443", segments: ["team", "app"], username: true)),
        ("ssh://git@ghe.example.com:2222/team/app.git",
         Parsed(host: "ghe.example.com", segments: ["team", "app"], username: true)),
        ("https://user:tok@github.com/o/r", Parsed(host: "github.com", segments: ["o", "r"], password: true)),
        // The host is after the last `@`, the one ssh and curl reach.
        ("https://github.com@evil.example/o/r", Parsed(host: "evil.example", segments: ["o", "r"], username: true)),
        // GitLab subgroups, Bitbucket Data Center, Azure DevOps.
        ("https://gitlab.com/group/sub/proj.git", Parsed(host: "gitlab.com", segments: ["group", "sub", "proj"])),
        ("https://bitbucket.example.com/scm/PROJ/repo.git",
         Parsed(host: "bitbucket.example.com", segments: ["scm", "PROJ", "repo"])),
        ("https://bitbucket.example.com/scm/~user/repo.git",
         Parsed(host: "bitbucket.example.com", segments: ["scm", "~user", "repo"])),
        ("https://org@dev.azure.com/org/project/_git/repo",
         Parsed(host: "dev.azure.com", segments: ["org", "project", "_git", "repo"], username: true)),
        ("git@ssh.dev.azure.com:v3/org/project/repo",
         Parsed(host: "ssh.dev.azure.com", segments: ["v3", "org", "project", "repo"], username: true)),
        ("https://dev.azure.com/org/My%20Project/_git/my%20repo",
         Parsed(host: "dev.azure.com", segments: ["org", "My Project", "_git", "my repo"])),
    ] as [(String, Parsed?)] + [
        // Bent hosts: a wildcard, whitespace, an empty host (nothing after the `@`), a leading `-`.
        "https://*.example.com/o/r", "git@ho st:o/r", "git@:o/r", "https://u@/o/r", "git@-oops:o/r",
        // Empty, `.` and `..` segments, encoded or not, an encoded `/`, and a bad escape.
        "https://github.com//o/r", "https://github.com/o//r", "https://github.com/", "https://github.com/./r",
        "https://github.com/o/..", "https://github.com/o/%2E%2E", "https://github.com/o/r%2Fx",
        "https://github.com/o/r%",
        // Other transports and local paths.
        "http://github.com/o/r", "file:///tmp/o/r", "/srv/repo:x", "../repo",
    ].map { ($0, nil) })
    func parses(url: String, expected: Parsed?) {
        let parsed = RemoteURL(url).map {
            Parsed(host: $0.host, segments: $0.segments, username: $0.hasUsername, password: $0.hasPassword)
        }
        #expect(parsed == expected)
    }

    @Test("GitHub resolves its forms as before and still wants exactly two plain segments", arguments: [
        ("git@ghe.example.com:Team/app.git", HostedRepository(host: "ghe.example.com", owner: "Team", name: "app")),
        ("org-1@GHE.Example.com:/team/my.repo",
         HostedRepository(host: "ghe.example.com", owner: "team", name: "my.repo")),
        ("https://github.com/octo/hello.git", HostedRepository(host: "github.com", owner: "octo", name: "hello")),
        ("https://user@ghe.example.com:8443/team/app/",
         HostedRepository(host: "ghe.example.com:8443", owner: "team", name: "app")),
        ("ssh://git@ghe.example.com:2222/team/app.git",
         HostedRepository(host: "ghe.example.com", owner: "team", name: "app")),
        ("https://user:tok@github.com/o/r",HostedRepository(host: "github.com", owner: "o", name: "r")),
        ("https://gitlab.com/group/sub/proj.git", nil),
        ("https://github.com/o/my%20repo", nil),
        ("https://github.com/o/r%2Fx", nil),
    ] as [(String, HostedRepository?)])
    func gitHubRepository(url: String, expected: HostedRepository?) {
        #expect(GitHubClient.repository(fromRemoteURL: url) == expected)
    }

    @Test("GitLab keeps subgroups and strips the relative root from https remotes only", arguments: [
        // Relative root: stripped, subgroups kept.
        ("https://example.com/gitlab/group/sub/proj.git", "gitlab",
         HostedRepository(host: "example.com", path: ["group", "sub", "proj"])),
        ("https://example.com:8443/a/b/group/proj.git", "a/b",
         HostedRepository(host: "example.com:8443", path: ["group", "proj"])),
        ("https://gitlab.com/group/sub/sub2/proj.git", nil,
         HostedRepository(host: "gitlab.com", path: ["group", "sub", "sub2", "proj"])),
        // An https remote not under the relative root, a near-miss root, or one segment left: nothing.
        ("https://example.com/group/sub/proj.git", "gitlab", nil),
        ("https://example.com/gitlabx/group/proj.git", "gitlab", nil),
        ("https://example.com/gitlab/proj.git", "gitlab", nil),
        ("https://example.com/gitlab/group/my%20proj.git", "gitlab", nil),
        ("https://example.com/gitlab/group/proj.git", "../gitlab", nil),
        // ssh and scp remotes never carry the root, so nothing is stripped, even a first segment that matches it.
        ("git@example.com:group/sub/sub2/proj.git", "gitlab",
         HostedRepository(host: "example.com", path: ["group", "sub", "sub2", "proj"])),
        ("ssh://git@example.com:2222/group/sub/proj.git", "gitlab",
         HostedRepository(host: "example.com", path: ["group", "sub", "proj"])),
        ("git@example.com:gitlab/group/proj.git", "gitlab",
         HostedRepository(host: "example.com", path: ["gitlab", "group", "proj"])),
    ] as [(String, String?, HostedRepository?)])
    func gitLabRepository(url: String, basePath: String?, expected: HostedRepository?) {
        #expect(GitLabClient.repository(fromRemoteURL: url, basePath: basePath) == expected)
    }

    @Test("an account's kind resolves its remotes: GitLab subgroups and base paths, GitHub's two segments as before",
          arguments: [
        (HostingKind.gitlab, "https://gitlab.com/group/sub/proj.git", nil,
         HostedRepository(host: "gitlab.com", path: ["group", "sub", "proj"])),
        (.gitlab, "https://example.com/gitlab/group/sub/proj.git", "gitlab",
         HostedRepository(host: "example.com", path: ["group", "sub", "proj"])),
        (.gitlab, "git@example.com:group/sub/proj.git", "gitlab",
         HostedRepository(host: "example.com", path: ["group", "sub", "proj"])),
        (.gitlab, "https://example.com/group/proj.git", "gitlab", nil),
        (.github, "https://github.com/octo/hello.git", nil,
         HostedRepository(host: "github.com", owner: "octo", name: "hello")),
        (.github, "git@ghe.example.com:Team/app.git", "ignored",
         HostedRepository(host: "ghe.example.com", owner: "Team", name: "app")),
        (.github, "https://gitlab.com/group/sub/proj.git", nil, nil),
    ] as [(HostingKind, String, String?, HostedRepository?)])
    func kindRepository(kind: HostingKind, url: String, basePath: String?, expected: HostedRepository?) {
        #expect(kind.repository(fromRemoteURL: url, basePath: basePath) == expected)
        if kind == .github { #expect(expected == GitHubClient.repository(fromRemoteURL: url)) }
    }

    @Test("a repository's path splits into owner and name, and the owner/name init round-trips")
    func repositoryPath() {
        let repo = HostedRepository(host: "gitlab.com", path: ["group", "sub", "proj"])
        #expect(repo.owner == "group/sub")
        #expect(repo.name == "proj")
        #expect(repo == HostedRepository(host: "gitlab.com", owner: "group/sub", name: "proj"))
        let slashedName = HostedRepository(host: "github.com", owner: "octo", name: "a/b")
        #expect(slashedName.path == ["octo", "a/b"])
        #expect(slashedName.owner == "octo")
        #expect(slashedName.name == "a/b")
    }
}
