// Builds the complete environment of a git child process (GitRunner inherits nothing): the profile is
// injected as command-scope config (`GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n`, which beats
// `.git/config`) and `GIT_SSH_COMMAND`, and git never prompts.
//
// Reads (status, log, diff, show, for-each-ref, watcher refreshes) also get a safety block, because a
// downloaded repo's `.git/config`, `.git/info/attributes` and hooks could otherwise make an automatic read
// run a command: no fsmonitor hook, no signature check (`gpg.program`), no inline submodule diff (a child
// `git diff` without `--no-ext-diff`), no index refresh write, no hooks, no external diff (`diff.external`),
// every filter driver and every diff driver (`textconv`, `command`) configured where the read runs
// disabled (an empty command: git fails to run it, so a read that does not pass `--no-ext-diff
// --no-textconv` fails instead of running it), no transport at all (`GIT_ALLOW_PROTOCOL` empty, which beats
// the repo's `protocol.<name>.allow`, and `GIT_NO_LAZY_FETCH` on git >= 2.44), so a partial clone's
// promisor remote never fetches through its `uploadpack` or `core.sshCommand`, and UTF-8 log output (a
// repo's `i18n.logOutputEncoding` such as UTF-16 would put NUL bytes in the NUL-terminated log records).
// Writes (user actions) keep the normal behavior, so git-lfs and hooks work.
//
// A fetch nobody clicked (auto-fetch) gets its own block, because it is network and runs on a timer in a
// repo that may be downloaded: only the ssh, https and git transports (no `file`, `ext` or remote helper,
// so a repo's `uploadpack`, `insteadOf` or `vcs` cannot run a local command), no git proxy command, no
// alternate refs command, no hooks, no fsmonitor, no submodule fetch, no prompt or askpass (an askpass that
// fails also beats a repo's `core.askPass`), no cookie file written, no gc or maintenance, an ssh that gives
// up on a dead host, and only the credential helpers of the user's own config (system, global, Xcode's):
// the list is reset and refilled after the repo's `credential.*helper` entries. A repo that sets its own
// `http.*` or `remote.<name>.proxy` config is not fetched in the background at all, since those keys could
// send the user's credentials to a third party.
//
// The profile's account tokens (`GitCredential`, one per host) reach git only for network commands (`.network`,
// `.backgroundFetch`): for the credential at index `<n>`, env vars `HISTQ_GIT_TOKEN_<n>` and `HISTQ_GIT_USER_<n>`
// and a credential helper for its host alone, `credential.https://<host>.helper` reset (so the user's osxkeychain is
// not asked, and nothing is stored there) and then set to a shell function that prints the two variables. A token or
// a username is never in a config value or an argument (a process list shows those), and reads, local writes and the
// terminal never get them. The core never reads the Keychain: the caller passes the credentials in.
//
// Every child of git inherits its environment, so a command gets a token only when the gate
// (`networkToken(for:credentials:base:runner:cwd:)`) lets it: every URL it contacts, after `insteadOf` and
// `pushInsteadOf`, is `https://<host>/…` for the host of one of the credentials, and the repo's own config sets no
// network key (`http.*`, a remote's proxy, `url.*.insteadOf`, `credential.*`) that could send a token elsewhere. The
// command then gets the credentials of the hosts its URLs reach, and no other. Such a command runs
// with the `.network` block: the https transport alone (no `ext`, `file` or remote helper of the repo's
// `remote.<name>.vcs`), no askpass, no submodule, gc or maintenance, no fsmonitor, no alternate refs command, no
// credential helper but the token's, redirects on the first request only, and no hook (a fetch or clone) or only
// the repo's pre-push hook (a push), which runs without the token unless it is git-lfs's generated stub (git-lfs
// then gets it for its upload). So the token is seen by git and its https transport, the token helper and, on a
// push from a git-lfs repo, the user's git-lfs; nothing the repo configures runs with it. Any other network
// command runs with the plain write environment and no token, so the user's own helpers answer.
import Foundation

public enum GitInvocation {
    public enum Access: Sendable, Equatable {
        /// A user action: the repo's hooks, filters and helpers run as with the git CLI.
        case write
        /// A user action that talks to a remote and passed the token gate (`networkToken(for:...)`): `.write`
        /// plus the hardened block of `kind` and the profile's token helper.
        case network(NetworkKind)
        /// An automatic read in a folder whose config names `filterDrivers` and `diffDrivers` (see
        /// `drivers(runner:cwd:env:)`).
        case read(filterDrivers: [String], diffDrivers: [String] = [])
        /// A fetch nobody clicked, with the user's own `credentialHelpers` (see
        /// `credentialHelpers(runner:cwd:env:)`).
        case backgroundFetch(credentialHelpers: [ConfigEntry])

        /// The accesses that talk to a remote and so may carry the token.
        var isNetwork: Bool {
            switch self {
            case .network, .backgroundFetch: true
            case .write, .read: false
            }
        }
    }

    /// What a token-carrying command runs as.
    public enum NetworkKind: Sendable, Equatable {
        /// A fetch or a clone: no hook runs.
        case fetch
        /// A push: `core.hooksPath` is `hooksPath`, a folder whose only hook runs the repo's own pre-push hook
        /// without the token (`prePushHooksFolder(runner:cwd:env:)`), so the
        /// reference-transaction hook git runs as it updates `refs/remotes/...` stays off.
        case push(hooksPath: String)
    }

    /// One config entry as git lists it: `credential.https://github.com.helper` and its value.
    public struct ConfigEntry: Sendable, Equatable {
        public var key: String
        public var value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    /// The base every invocation starts from: `path` as PATH, HOME, and the few inherited variables ssh and gpg
    /// need to reach their agents. Reads use the default, the fixed `GitExecutable.fixedPath`, so they never wait
    /// for the login shell; writes and network commands pass `LoginShellPath.value()` (a GUI app only gets
    /// launchd's PATH, which misses git-lfs, gpg and the tools hooks call).
    public static func baseEnvironment(
        path: String = GitExecutable.fixedPath, home: String = NSHomeDirectory(),
        inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = ["PATH": path, "HOME": home]
        for key in ["USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK", "GNUPGHOME"] {
            if let value = inherited[key] { env[key] = value }
        }
        return env
    }

    /// `base` plus the profile and, for reads, background fetches and token-carrying commands, their safety block.
    /// Config entries are appended after any `GIT_CONFIG_*` entries already in `base`; within command scope the last
    /// one wins.
    ///
    /// `credentials` are the tokens git may use. Only `.network` and `.backgroundFetch` use them, and only those
    /// `usableCredentials(_:)` keeps; every other access drops them. They do not check the URLs: pass only the set the
    /// gate matched (`networkToken(for:...)`, `.attach`), as `GitOperations`, `backgroundFetchEnvironment` and
    /// `cloneEnvironment` do.
    public static func environment(
        profile: Profile?, base: [String: String], access: Access = .write, credentials: [GitCredential] = []
    ) -> [String: String] {
        // Only the token helpers below may set them, whatever `base` carries.
        var env = base.filter { !isCredentialVariable($0.key) }
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        var config: [(String, String)] = []
        if let profile {
            config += identityConfig(profile)
            config += signingConfig(profile)
        }
        env["GIT_SSH_COMMAND"] = sshCommand(profile?.ssh ?? .agent)
        if case .read(let filterDrivers, let diffDrivers) = access {
            env["GIT_OPTIONAL_LOCKS"] = "0"
            env["GIT_NO_LAZY_FETCH"] = "1"
            // An empty allow list: no transport (`file`, `ssh`, `ext`, remote helpers...) may run.
            env["GIT_ALLOW_PROTOCOL"] = ""
            config += readSafetyConfig
            for driver in filterDrivers {
                let section = "filter.\(driver)"
                config += [("\(section).clean", ""), ("\(section).smudge", ""), ("\(section).process", ""),
                           ("\(section).required", "false")]
            }
            for driver in diffDrivers {
                config += [("diff.\(driver).textconv", ""), ("diff.\(driver).command", "")]
            }
        }
        if case .backgroundFetch(let credentialHelpers) = access {
            env["GIT_ALLOW_PROTOCOL"] = "ssh:https:git"
            // Set but empty: git then ignores every `core.gitProxy` and connects to a git:// host itself.
            env["GIT_PROXY_COMMAND"] = ""
            env["GIT_ASKPASS"] = "/usr/bin/false"
            env["SSH_ASKPASS"] = "/usr/bin/false"
            env["GIT_SSH_COMMAND"]? += " -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=2"
            config += backgroundFetchConfig
            // An empty helper clears the list git built so far (every scope and URL, the repo's included);
            // the user's own helpers then come back in their order.
            config.append(("credential.helper", ""))
            config += credentialHelpers.map { ($0.key, $0.value) }
        }
        if case .network(let kind) = access {
            // https alone: the gate checked the URLs, and a repo's `remote.<name>.vcs` names a helper of its own.
            env["GIT_ALLOW_PROTOCOL"] = "https"
            env["GIT_ASKPASS"] = "/usr/bin/false"
            env["SSH_ASKPASS"] = "/usr/bin/false"
            config += tokenNetworkConfig
            switch kind {
            case .fetch:
                config.append(("core.hooksPath", "/dev/null"))
            case .push(let hooksPath):
                // A signed push would run `gpg.program`, which the repo may set.
                config += [("core.hooksPath", hooksPath), ("push.gpgSign", "false")]
            }
        }
        // Last, so no helper entry of any scope comes after the reset for a credential's host.
        let usable = access.isNetwork ? usableCredentials(credentials) : []
        if !usable.isEmpty {
            switch access {
            case .network:
                // No helper but the token's, so none of the user's (or another host's after a redirect) runs in an
                // environment that holds the variable.
                config.append(("credential.helper", ""))
            case .backgroundFetch:
                // The gate let every remote through as https: no other transport.
                env["GIT_ALLOW_PROTOCOL"] = "https"
            case .write, .read:
                break
            }
            for (index, credential) in usable.enumerated() {
                env["HISTQ_GIT_TOKEN_\(index)"] = credential.token
                env["HISTQ_GIT_USER_\(index)"] = credential.gitUsername
                let key = "credential.https://\(credential.host).helper"
                config += [(key, ""), (key, tokenHelper(index))]
            }
        }
        append(config, to: &env)
        return env
    }

    /// The shell-function helper git runs for the host of the credential at `index`: it answers `get` with the
    /// username and token read from `HISTQ_GIT_USER_<index>` and `HISTQ_GIT_TOKEN_<index>` (expanded by the shell, so
    /// neither is in an argument nor in the helper's text; `printf '%s'` prints them as they are, where some `echo`s
    /// expand backslashes) and ignores `store` and `erase`. Only the index, a number, is in the text.
    public static func tokenHelper(_ index: Int) -> String {
        #"!f() { test "$1" = get && printf 'username=%s\npassword=%s\n' "$HISTQ_GIT_USER_\#(index)" "#
            + #""$HISTQ_GIT_TOKEN_\#(index)"; }; f"#
    }

    /// The credentials git may get, in order, each with its host as `HostingHTTP.validatedHost` gives it (lowercase,
    /// with its port if it has one); the position in this list is the `<n>` of its variables. A credential is dropped
    /// when its host could widen or bend the config key (`*`, `/`, `@`, whitespace), its token could break the
    /// helper's output lines (`HostingHTTP.isUsableToken`) or its username is not `GitCredential.isSafeUsername`; a
    /// second credential for a host already listed is dropped too.
    static func usableCredentials(_ credentials: [GitCredential]) -> [GitCredential] {
        var usable: [GitCredential] = []
        for var credential in credentials {
            guard let host = HostingHTTP.validatedHost(credential.host), HostingHTTP.isUsableToken(credential.token),
                  GitCredential.isSafeUsername(credential.username), !usable.contains(where: { $0.host == host })
            else { continue }
            credential.host = host
            usable.append(credential)
        }
        return usable
    }

    /// A variable that carries a credential (`HISTQ_GIT_TOKEN`, `HISTQ_GIT_TOKEN_<n>`, `HISTQ_GIT_USER_<n>`), which
    /// only the token helpers may set.
    static func isCredentialVariable(_ key: String) -> Bool {
        key.hasPrefix("HISTQ_GIT_TOKEN") || key.hasPrefix("HISTQ_GIT_USER_")
    }

    /// The variables a terminal opened for `profile` adds to the user's own environment: identity and signing as
    /// command-scope config (`GIT_CONFIG_COUNT` from 0: they replace an inherited list) and, for a key file, the
    /// ssh command. Never a token or a credential helper. Unlike `environment(profile:base:access:credentials:)` it
    /// keeps ssh and git interactive (no `BatchMode`, no `GIT_TERMINAL_PROMPT=0`), since the user can answer a prompt
    /// there; with the SSH agent it sets no ssh command, so the user's own `core.sshCommand` and ssh config apply.
    public static func terminalEnvironment(profile: Profile?) -> [String: String] {
        guard let profile else { return [:] }
        var env: [String: String] = [:]
        if case .keyFile(let path) = profile.ssh {
            env["GIT_SSH_COMMAND"] = "ssh -i \(shellQuoted(path)) -o IdentitiesOnly=yes"
        }
        append(identityConfig(profile) + signingConfig(profile), to: &env)
        return env
    }

    /// The whole environment of a terminal's shell: `base` (Histq's own, the user's launchd environment) without what
    /// belongs to Histq or to a git command it runs, then the terminal's type, a UTF-8 `LANG` when there is none, and
    /// `terminalEnvironment(profile:)`. No `HISTQ_GIT_TOKEN*` or `HISTQ_GIT_USER_*` variable, credential helper or
    /// askpass program ever reaches it.
    public static func terminalProcessEnvironment(base: [String: String], profile: Profile?) -> [String: String] {
        var env = base.filter { !isHistqOwned($0.key) }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"]?.isEmpty ?? true { env["LANG"] = defaultLanguage() }
        env.merge(terminalEnvironment(profile: profile)) { _, profileValue in profileValue }
        return env.filter { !$0.key.hasPrefix("HISTQ_") }
    }

    /// Variables of Histq's process, not the user's: the token variable, a git command's config list (the profile's
    /// replaces it from 0), the askpass programs a git command gets (`/usr/bin/false`, which would make every
    /// password prompt in the shell fail), the launch's loader and bundle identity.
    private static func isHistqOwned(_ key: String) -> Bool {
        key.hasPrefix("HISTQ_") || key == "GIT_CONFIG_COUNT" || key == "GIT_CONFIG_PARAMETERS"
            || key.hasPrefix("GIT_CONFIG_KEY_") || key.hasPrefix("GIT_CONFIG_VALUE_") || key.hasPrefix("DYLD_")
            || key == "GIT_ASKPASS" || key == "SSH_ASKPASS"
            || key == "__CFBundleIdentifier" || key == "XPC_SERVICE_NAME"
    }

    /// The system locale as a UTF-8 `LANG` (`en_US.UTF-8`), as Terminal.app sets it; en_US when the system has no
    /// such locale (a region without its own, `en_VN`).
    private static func defaultLanguage() -> String {
        let identifier = Locale.current.identifier.split(separator: "@").first.map(String.init) ?? ""
        let candidate = "\(identifier).UTF-8"
        return !identifier.isEmpty && FileManager.default.fileExists(atPath: "/usr/share/locale/\(candidate)")
            ? candidate : "en_US.UTF-8"
    }

    /// The background fetch environment for a `git fetch --all` run in `cwd`: lists the user's credential helpers
    /// first, and throws `BackgroundFetchError.repoSetsNetworkConfig` for a repo with its own http or proxy config.
    /// `credentials` adds the token helpers of the hosts the repo's remotes reach after the replayed helpers (see
    /// `environment(profile:base:access:credentials:)`) only when the gate lets every remote of the repo have one.
    public static func backgroundFetchEnvironment(
        profile: Profile?, base: [String: String], runner: GitRunner, cwd: URL, credentials: [GitCredential] = []
    ) async throws -> [String: String] {
        // A read environment, so a token helper is never listed and replayed as one of the user's helpers.
        let listingEnv = environment(profile: nil, base: base, access: .read(filterDrivers: []))
        let helpers = try await credentialHelpers(runner: runner, cwd: cwd, env: listingEnv)
        var gated: [GitCredential] = []
        if !credentials.isEmpty, let remotes = try? await remoteNames(runner: runner, cwd: cwd, env: listingEnv),
           case .attach(let matched) = await networkToken(
               for: .fetch(remotes: remotes), credentials: credentials, base: base, runner: runner, cwd: cwd)
        {
            gated = matched
        }
        return environment(
            profile: profile, base: base, access: .backgroundFetch(credentialHelpers: helpers), credentials: gated)
    }

    /// The environment of a clone of `url`: `.network(.fetch)` with the token of the URL's host when the gate lets
    /// the URL have it (`NetworkTarget.clone`), else the plain write environment, so the user's own helpers answer.
    public static func cloneEnvironment(
        url: String, profile: Profile?, base: [String: String], credentials: [GitCredential], runner: GitRunner
    ) async -> [String: String] {
        let decision = await networkToken(
            for: .clone(url: url), credentials: credentials, base: base, runner: runner, cwd: URL(filePath: "/"))
        guard case .attach(let matched) = decision else {
            return environment(profile: profile, base: base, access: .write)
        }
        return environment(profile: profile, base: base, access: .network(.fetch), credentials: matched)
    }

    /// The `credential.helper` and `credential.<url>.helper` entries (empty resets included, in git's order) of
    /// every scope git reads in `cwd` but the repo's own (`local`, `worktree`): system, global, command and
    /// `unknown`, which is where Apple's git keeps Xcode's `osxkeychain` (not listed by `--system`). Listed in
    /// `cwd`, so a global `includeIf "gitdir:..."` applies as it does for git; an included file has the scope
    /// of the file that includes it. A valueless entry (which makes git fail anyway) is skipped; a value that is
    /// not valid UTF-8 and any git failure but "no match" throw, so a fetch never runs with a partial list.
    ///
    /// The same listing throws `BackgroundFetchError.repoSetsNetworkConfig` when the repo's own scopes set any
    /// `http.*` key (`http.<url>.*` too) or a `remote.<name>.proxy`: a repo's proxy, `sslVerify=false`,
    /// `sslCAInfo` or `extraHeader` could make a fetch nobody clicked hand the user's stored credentials to a
    /// third party. A fetch the user clicks still runs with them.
    public static func credentialHelpers(runner: GitRunner, cwd: URL, env: [String: String]) async throws
        -> [ConfigEntry]
    {
        let listing = try await networkConfig(runner: runner, cwd: cwd, env: env)
        // The repo's own helpers are dropped by the reset and its `url.*` rewrites are checked by the transport
        // list; its http and proxy keys stop the fetch.
        let blocking = listing.repoKeys.filter { !$0.hasPrefix("credential.") && !$0.hasPrefix("url.") }
        if !blocking.isEmpty { throw BackgroundFetchError.repoSetsNetworkConfig(keys: blocking) }
        return listing.helpers
    }

    public enum BackgroundFetchError: Error, Equatable, Sendable {
        /// The repo's own config sets these `http.*` or `remote.<name>.proxy` keys, so it is not fetched unless
        /// the user asks.
        case repoSetsNetworkConfig(keys: [String])
    }

    /// One listing of the network config git reads in `cwd` (under a read environment, so it runs nothing): the
    /// user's own credential helper entries (see `credentialHelpers(runner:cwd:env:)`), and every `credential.*`,
    /// `http.*`, `remote.<name>.proxy`, `url.<base>.insteadOf` and `url.<base>.pushInsteadOf` key the repo's own
    /// scopes set (local, worktree and the files they include; valueless keys too). Keys come back as git
    /// canonicalizes them: section and variable lowercase.
    private static func networkConfig(runner: GitRunner, cwd: URL, env: [String: String]) async throws
        -> (helpers: [ConfigEntry], repoKeys: [String])
    {
        let pattern = #"^(credential\..*|http\..*|remote\..*\.proxy|url\..*\.(insteadof|pushinsteadof))$"#
        let result = try await runner.run(
            ["config", "-z", "--show-scope", "--get-regexp", pattern], cwd: cwd, env: env,
            timeout: .seconds(10), allowedExitCodes: [0, 1])
        let userScopes: Set<String> = ["system", "global", "command", "unknown"]
        let credentialPrefix = Array("credential.".utf8)
        let helperSuffix = Array(".helper".utf8)
        var helpers: [ConfigEntry] = []
        var repoKeys: [String] = []
        // `<scope>\0<key>\n<value>\0` per entry; a valueless entry has no `\n<value>`.
        let fields = result.stdout.split(separator: 0, omittingEmptySubsequences: false)
        var index = 0
        while index + 1 < fields.count {
            let scope = String(decoding: fields[index], as: UTF8.self)
            let entry = fields[index + 1]
            index += 2
            let newline = entry.firstIndex(of: UInt8(ascii: "\n"))
            let keyBytes = entry[..<(newline ?? entry.endIndex)]
            guard userScopes.contains(scope) else {
                repoKeys.append(String(decoding: keyBytes, as: UTF8.self))
                continue
            }
            // `credential.helper` or `credential.<url>.helper`; the user's other keys are theirs to keep.
            let isHelper = keyBytes.starts(with: credentialPrefix)
                && (keyBytes.elementsEqual("credential.helper".utf8) || keyBytes.suffix(helperSuffix.count)
                    .elementsEqual(helperSuffix))
            guard isHelper, let newline else { continue }
            guard let key = String(validating: keyBytes, as: UTF8.self),
                  let value = String(validating: entry[(newline + 1)...], as: UTF8.self)
            else { throw ReadSafetyError.credentialHelperNotUTF8 }
            helpers.append(ConfigEntry(key: key, value: value))
        }
        return (helpers, repoKeys)
    }

    // MARK: - Token gate

    /// What a network command contacts, for `networkToken(for:credentials:base:runner:cwd:)`.
    public enum NetworkTarget: Sendable, Equatable {
        /// A fetch from these remotes (by name): every fetch URL of each.
        case fetch(remotes: [String])
        /// A push to this remote (by name): every push URL (`pushurl`, else `url`).
        case push(remote: String)
        /// A clone of this URL: there is no repository yet.
        case clone(url: String)
        /// A fetch (or clone) of the submodule at this path (relative to the top of the repo's worktree, as in
        /// `.gitmodules`), one level only: the URL the repo's config gives it and, once it has a git folder, every
        /// fetch URL of that repo.
        case submodule(path: String)
    }

    /// Whether a network command gets credentials, which, and why not.
    public enum TokenDecision: Sendable, Equatable {
        /// Every URL is `https://<host>/…` for the host of one of these credentials (the usable ones whose host a URL
        /// reaches, no other; hosts as `HostingHTTP.validatedHost` gives them) and the repo sets no network key of
        /// its own.
        case attach([GitCredential])
        /// No credential `usableCredentials(_:)` keeps.
        case noToken
        /// The repo's own config sets these keys (`credential.*`, `http.*`, `remote.<name>.proxy`,
        /// `url.<base>.insteadof`, `url.<base>.pushinsteadof`), any of which could send the token elsewhere.
        case repoNetworkConfig(keys: [String])
        /// A URL the command contacts is not `https://<host>/…` for any credential's host (or there is none).
        case otherURL
        /// Git could not list the config or the URLs: no token, as for any doubt.
        case lookupFailed
        /// The repo has submodules and these recursion keys are on (`submodule.recurse`,
        /// `fetch.recursesubmodules`, `push.recursesubmodules`): a token-carrying command never recurses, so it runs
        /// without the token, recursing as the user set.
        case submoduleRecursion(keys: [String])
    }

    /// The gate of the credentials: `.attach` only when `usableCredentials(_:)` keeps one, the repo in `cwd` sets no
    /// network key of its own nor, with submodules, a recursion key that is on (`submoduleRecursion`; not for a clone,
    /// nor for a submodule fetch, whose caller never recurses), and every URL `target` contacts passes
    /// `isTokenURL(_:host:)` for the host of one of them after the rewrites git applies (`remote get-url`:
    /// `insteadOf`, and `pushInsteadOf` for a push; `ls-remote --get-url` for a clone). All or nothing: one URL on no
    /// credential's host and the command gets none. `.attach` carries the credentials of the hosts the URLs reach
    /// alone, so a command never gets the token of a host it does not contact. The git runs read config only, under a
    /// read environment (no transport at all), so the gate never touches the network; a clone's URL is resolved in
    /// `/`, where no repository's config applies, and the URL as typed must pass too.
    public static func networkToken(
        for target: NetworkTarget, credentials: [GitCredential], base: [String: String], runner: GitRunner, cwd: URL
    ) async -> TokenDecision {
        let usable = usableCredentials(credentials)
        guard !usable.isEmpty else { return .noToken }
        let listingEnv = environment(profile: nil, base: base, access: .read(filterDrivers: []))
        var urls: [String] = []
        do {
            switch target {
            case .clone(let url):
                let resolved = try await runner.run(
                    ["ls-remote", "--get-url", "--end-of-options", url], cwd: URL(filePath: "/"), env: listingEnv,
                    timeout: .seconds(10))
                urls = [url] + lines(resolved.stdout)
            case .fetch(let remotes):
                let keys = try await networkConfig(runner: runner, cwd: cwd, env: listingEnv).repoKeys
                guard keys.isEmpty else { return .repoNetworkConfig(keys: keys) }
                for remote in remotes {
                    urls += try await remoteURLs(remote, push: false, runner: runner, cwd: cwd, env: listingEnv)
                }
            case .push(let remote):
                let keys = try await networkConfig(runner: runner, cwd: cwd, env: listingEnv).repoKeys
                guard keys.isEmpty else { return .repoNetworkConfig(keys: keys) }
                urls = try await remoteURLs(remote, push: true, runner: runner, cwd: cwd, env: listingEnv)
            case .submodule(let path):
                let keys = try await networkConfig(runner: runner, cwd: cwd, env: listingEnv).repoKeys
                guard keys.isEmpty else { return .repoNetworkConfig(keys: keys) }
                guard let submodule = try await submoduleURLs(path, runner: runner, cwd: cwd, env: listingEnv) else {
                    return .otherURL
                }
                guard submodule.repoKeys.isEmpty else { return .repoNetworkConfig(keys: submodule.repoKeys) }
                urls = submodule.urls
            }
        } catch {
            return .lookupFailed
        }
        guard !urls.isEmpty else { return .otherURL }
        var reached: Set<String> = []
        for url in urls {
            guard let credential = usable.first(where: { isTokenURL(url, host: $0.host) }) else { return .otherURL }
            reached.insert(credential.host)
        }
        let matched = usable.filter { reached.contains($0.host) }
        // A clone has no repo yet; a submodule's caller never recurses (the parent has `.gitmodules` anyway).
        switch target {
        case .clone, .submodule: return .attach(matched)
        case .fetch, .push: break
        }
        do {
            let keys = try await submoduleRecursion(runner: runner, cwd: cwd, env: listingEnv)
            if !keys.isEmpty { return .submoduleRecursion(keys: keys) }
        } catch {
            return .lookupFailed
        }
        return .attach(matched)
    }

    /// The submodule recursion keys that are on in `cwd` (`submodule.recurse` true, `fetch.recurseSubmodules` or
    /// `push.recurseSubmodules` anything but off; any scope, the last value wins, a valueless key is true) when the
    /// repo has submodules (`.gitmodules` at the top of its worktree, or a `submodule.<name>.<key>` or
    /// `submodule.active` entry); empty otherwise. A token-carrying command turns recursion off, so with it on the
    /// command would act unlike the same one without the token.
    static func submoduleRecursion(runner: GitRunner, cwd: URL, env: [String: String]) async throws -> [String] {
        let recursion: Set<String> = ["submodule.recurse", "fetch.recursesubmodules", "push.recursesubmodules"]
        let result = try await runner.run(
            ["config", "-z", "--get-regexp", #"^(submodule\..*|fetch\.recursesubmodules|push\.recursesubmodules)$"#],
            cwd: cwd, env: env, timeout: .seconds(10), allowedExitCodes: [0, 1])
        var values: [String: String] = [:]
        var hasSubmodules = false
        // `<key>\n<value>\0` per entry; a valueless entry has no `\n<value>`.
        for entry in result.stdout.split(separator: 0) {
            let parts = String(decoding: entry, as: UTF8.self)
                .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0])
            if recursion.contains(key) {
                values[key] = parts.count > 1 ? String(parts[1]).lowercased() : "true"
            } else if key == "submodule.active" || key.split(separator: ".").count >= 3 {
                hasSubmodules = true
            }
        }
        if !hasSubmodules, let top = try? await runner.run(
            ["rev-parse", "--show-toplevel"], cwd: cwd, env: env, timeout: .seconds(10)).text
        {
            hasSubmodules = FileManager.default.fileExists(
                atPath: URL(filePath: top.trimmingCharacters(in: .newlines)).appending(path: ".gitmodules").path)
        }
        guard hasSubmodules else { return [] }
        let off: Set<String> = ["false", "no", "off", "0", ""]
        return values.filter { !off.contains($0.value) }.map(\.key).sorted()
    }

    /// Whether git may send the token for `host` (as `HostingHTTP.validatedHost` gives it) to `url`: exactly
    /// `https://<host>/…`, with the scheme in lowercase, no userinfo, the same port as `host` (none when it has
    /// none) and only printable ASCII. The authority is everything up to the first `/` and must equal `host` once
    /// validated, so `@`, `?`, `#`, `%`, `\` and a trailing dot all fail.
    public static func isTokenURL(_ url: String, host: String) -> Bool {
        let scheme = "https://"
        guard url.hasPrefix(scheme), url.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            return false
        }
        let rest = url.dropFirst(scheme.count)
        let authority = rest.prefix { $0 != "/" }
        guard authority.count < rest.count, let validated = HostingHTTP.validatedHost(String(authority)) else {
            return false
        }
        return validated == host
    }

    /// The remotes of the repo in `cwd` (`git remote`), as `git fetch --all` goes through them.
    public static func remoteNames(runner: GitRunner, cwd: URL, env: [String: String]) async throws -> [String] {
        lines(try await runner.run(["remote"], cwd: cwd, env: env, timeout: .seconds(10)).stdout)
    }

    /// Every fetch URL of `remote` (or push URL with `push`), rewritten as git rewrites it; throws for a name that
    /// is no remote.
    private static func remoteURLs(
        _ remote: String, push: Bool, runner: GitRunner, cwd: URL, env: [String: String]
    ) async throws -> [String] {
        let args = ["remote", "get-url"] + (push ? ["--push"] : []) + ["--all", "--end-of-options", remote]
        return lines(try await runner.run(args, cwd: cwd, env: env, timeout: .seconds(10)).stdout)
    }

    /// What a fetch of the submodule at `path` of the repo in `cwd` contacts: every `submodule.<name>.url` of the
    /// repo's config (`git submodule init` fills it, a relative `.gitmodules` URL already resolved against the
    /// repo's remote), as typed and after the user's rewrites (`ls-remote --get-url` in `/`, as for a clone); then,
    /// when the submodule has a git folder (checked out at `path`, or left in `modules/<name>` of the repo's git
    /// folder, which `git submodule update` reuses), every fetch URL of that repo and the network keys its own
    /// config sets. The name is the one `.gitmodules` gives `path`. Nil (no token) for no such path, a name or path
    /// git would refuse, or no URL. Every value is an argument, never shell text.
    private static func submoduleURLs(
        _ path: String, runner: GitRunner, cwd: URL, env: [String: String]
    ) async throws -> (urls: [String], repoKeys: [String])? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !components.contains(".."), !components.contains(".") else {
            return nil
        }
        let top = try await gitLine(["rev-parse", "--show-toplevel"], runner: runner, cwd: cwd, env: env)
        // `.gitmodules` alone, without its includes (`--file` reads none).
        let listing = try await runner.run(
            ["config", "-z", "--file", top + "/.gitmodules", "--get-regexp", #"^submodule\..*\.path$"#],
            cwd: cwd, env: env, timeout: .seconds(10), allowedExitCodes: [0, 1])
        var names: [String] = []
        // `<key>\n<value>\0` per entry.
        for entry in listing.stdout.split(separator: 0) {
            let parts = String(decoding: entry, as: UTF8.self)
                .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[1] == path else { continue }
            names.append(String(parts[0].dropFirst("submodule.".count).dropLast(".path".count)))
        }
        guard names.count == 1, let name = names.first, !name.isEmpty,
              !name.split(separator: "/", omittingEmptySubsequences: false).contains("..")
        else { return nil }
        let configured = lines(try await runner.run(
            ["config", "--get-all", "submodule.\(name).url"], cwd: cwd, env: env,
            timeout: .seconds(10), allowedExitCodes: [0, 1]).stdout)
        guard !configured.isEmpty else { return nil }
        var urls: [String] = []
        for url in configured {
            let resolved = try await runner.run(
                ["ls-remote", "--get-url", "--end-of-options", url], cwd: URL(filePath: "/"), env: env,
                timeout: .seconds(10))
            urls += [url] + lines(resolved.stdout)
        }
        // The submodule's own repo, checked that git finds it there and not the parent around it.
        let repo: URL
        if FileManager.default.fileExists(atPath: top + "/" + path + "/.git") {
            repo = URL(filePath: top + "/" + path, directoryHint: .isDirectory)
            let found = try await gitLine(["rev-parse", "--show-toplevel"], runner: runner, cwd: repo, env: env)
            guard found == top + "/" + path else { throw SubmoduleRepoMismatch() }
        } else {
            let modules = try await gitLine(
                ["rev-parse", "--path-format=absolute", "--git-path", "modules/" + name], runner: runner, cwd: cwd,
                env: env)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: modules, isDirectory: &isFolder), isFolder.boolValue else {
                return (urls, [])
            }
            repo = URL(filePath: modules, directoryHint: .isDirectory)
            let found = try await gitLine(["rev-parse", "--absolute-git-dir"], runner: runner, cwd: repo, env: env)
            guard found == modules else { throw SubmoduleRepoMismatch() }
        }
        let repoKeys = try await networkConfig(runner: runner, cwd: repo, env: env).repoKeys
        for remote in try await remoteNames(runner: runner, cwd: repo, env: env) {
            urls += try await remoteURLs(remote, push: false, runner: runner, cwd: repo, env: env)
        }
        return (urls, repoKeys)
    }

    /// Git found another repo than the submodule's (an empty or broken folder inside the parent's worktree).
    private struct SubmoduleRepoMismatch: Error {}

    /// Git's one line of output, without its newline.
    private static func gitLine(_ args: [String], runner: GitRunner, cwd: URL, env: [String: String]) async throws
        -> String
    {
        let text = try await runner.run(args, cwd: cwd, env: env, timeout: .seconds(10)).text
        return text.hasSuffix("\n") ? String(text.dropLast()) : text
    }

    /// The lines of git's output without the last newline; an empty line stays (an empty URL fails the gate).
    private static func lines(_ output: Data) -> [String] {
        var lines = String(decoding: output, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// A new folder for `core.hooksPath` during a token-carrying push. Its only hook, `pre-push`, stands for the
    /// repo's own pre-push hook (found where git finds it with `env`, the write environment: the repo's
    /// `core.hooksPath` or `.git/hooks`), so no other hook runs: the reference-transaction hook that a push runs as
    /// it updates `refs/remotes/...` stays off. The caller removes the folder after the push.
    ///
    /// The repo's hook never sees a token. Only git-lfs's generated stub (`isLFSPrePushStub(_:)`, checked here, on
    /// an executable regular file once symlinks are resolved, in a repo whose own config names no git-lfs transfer
    /// agent or extension, programs git-lfs would run) gets them, for git-lfs's upload: the wrapper then runs the
    /// stub's two commands itself, so nothing read later from the repo's file runs with a token. Any other hook runs
    /// with the same arguments and input after the wrapper puts back what it would see without the tokens, from `env`:
    /// `HISTQ_GIT_TOKEN_<n>` and `HISTQ_GIT_USER_<n>` of every one of `credentials` (the set the push runs with, as
    /// `environment(profile:base:access:credentials:)` numbers it) unset, and `GIT_CONFIG_COUNT`,
    /// `GIT_ALLOW_PROTOCOL`, `GIT_ASKPASS` and `SSH_ASKPASS` as `env` has them (unset when it has none). The
    /// `.network` block and the tokens' entries all come after the write environment's own config entries, so the
    /// count drops them: a `git` the hook runs (over ssh too) sees the write environment, the user's own credential
    /// helpers and the repo's hooks, as in a push without the tokens.
    public static func prePushHooksFolder(
        runner: GitRunner, cwd: URL, env: [String: String], credentials: [GitCredential]
    ) async throws -> URL {
        let output = try await runner.run(
            ["rev-parse", "--path-format=absolute", "--git-path", "hooks/pre-push"], cwd: cwd, env: env,
            timeout: .seconds(10)).text
        let hook = output.hasSuffix("\n") ? String(output.dropLast()) : output
        let isLFS = try await isLFSHook(hook, runner: runner, cwd: cwd, env: env)
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "HistqHooks-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let script = folder.appending(path: "pre-push")
        let body = isLFS
            ? "#!/bin/sh\n" + lfsStubCheck
                + #"{ printf >&2 '\n%s\n\n' "This repository is configured for Git LFS but 'git-lfs' was not found "#
                + #"on your path."; exit 2; }"# + "\nexec " + lfsStubCommand + "\n"
            // `exec`, so the hook's `$0` is its own path (hook managers find their files next to it).
            : "#!/bin/sh\nunset HISTQ_GIT_TOKEN\n"
                // Every index `credentials` could use: never fewer than the usable ones it numbers from 0.
                + credentials.indices.map { "unset HISTQ_GIT_TOKEN_\($0) HISTQ_GIT_USER_\($0)\n" }.joined()
                + ["GIT_CONFIG_COUNT", "GIT_ALLOW_PROTOCOL", "GIT_ASKPASS", "SSH_ASKPASS"].map { key in
                    env[key].map { "\(key)=\(shellQuoted($0))\nexport \(key)\n" } ?? "unset \(key)\n"
                }.joined()
                + "test -x \(shellQuoted(hook)) || exit 0\nexec \(shellQuoted(hook)) \"$@\"\n"
        do {
            try Data(body.utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return folder
    }

    private static let lfsStubCheck = "command -v git-lfs >/dev/null 2>&1 || "
    private static let lfsStubCommand = #"git lfs pre-push "$@""#

    /// Whether `contents` is the pre-push hook `git lfs install` writes, once lines are trimmed of spaces and tabs
    /// and blank and `#` lines (the shebang too) dropped. What is left must be exactly `git lfs pre-push "$@"`,
    /// after (git-lfs 1.x and later) exactly one line `command -v git-lfs >/dev/null 2>&1 || { <M>; exit 2; }`,
    /// where `<M>` is `printf >&2 "\n%s\n\n" "<text>"` (3.x) or `echo >&2 "\n<text>\n"` (1.x, 2.x) and `<text>`
    /// (translated by some releases) has no `"`, `$`, backquote or backslash, so the shell expands nothing in it.
    public static func isLFSPrePushStub(_ contents: String) -> Bool {
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t")) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard lines.last == lfsStubCommand else { return false }
        switch lines.count {
        case 1: return true
        case 2: break
        default: return false
        }
        let suffix = "; exit 2; }"
        guard lines[0].hasPrefix(lfsStubCheck + "{ "), lines[0].hasSuffix(suffix) else { return false }
        let message = lines[0].dropFirst(lfsStubCheck.count + 2).dropLast(suffix.count)
        let inert = { (text: Substring) in !text.isEmpty && !text.contains { "\"$`\\".contains($0) } }
        for (prefix, end) in [(#"printf >&2 "\n%s\n\n" ""#, "\""), (#"echo >&2 "\n"#, #"\n""#)] {
            if message.hasPrefix(prefix), message.hasSuffix(end), message.count > prefix.count + end.count,
               inert(message.dropFirst(prefix.count).dropLast(end.count))
            {
                return true
            }
        }
        return false
    }

    /// Whether the repo's pre-push hook at `path` may get the token: an executable regular file (symlinks
    /// resolved) of at most 4 KB holding git-lfs's stub, in a repo whose own config (any scope but system, global,
    /// command and unknown) sets no `lfs.customtransfer.*`, `*standalonetransferagent` or `lfs.extension.*` key, which
    /// would make git-lfs run a program the repo names.
    private static func isLFSHook(_ path: String, runner: GitRunner, cwd: URL, env: [String: String]) async throws
        -> Bool
    {
        let resolved = URL(filePath: path).resolvingSymlinksInPath()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              FileManager.default.isExecutableFile(atPath: resolved.path),
              let data = try? Data(contentsOf: resolved), data.count <= 4096,
              let contents = String(validating: data, as: UTF8.self), isLFSPrePushStub(contents)
        else { return false }
        let pattern = #"^lfs\.(customtransfer\..*|(.*\.)?standalonetransferagent|extension\..*)$"#
        let result = try await runner.run(
            ["config", "-z", "--show-scope", "--name-only", "--get-regexp", pattern], cwd: cwd, env: env,
            timeout: .seconds(10), allowedExitCodes: [0, 1])
        let userScopes: Set<String> = ["system", "global", "command", "unknown"]
        // `<scope>\0<key>\0` per entry.
        let fields = result.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        return stride(from: 0, to: fields.count - 1, by: 2).allSatisfy { userScopes.contains(fields[$0]) }
    }

    /// The read environment for a read run in `cwd`: lists the filter and diff drivers configured there first (one
    /// listing), or takes them from `cache` while none of the files that listing read has changed (see
    /// `ReadEnvironmentCache`).
    public static func readEnvironment(
        profile: Profile?, base: [String: String], runner: GitRunner, cwd: URL, cache: ReadEnvironmentCache? = nil
    ) async throws -> [String: String] {
        let listingEnv = environment(profile: profile, base: base, access: .read(filterDrivers: []))
        let listed = if let cache {
            try await cache.drivers(runner: runner, cwd: cwd, env: listingEnv)
        } else {
            try await drivers(runner: runner, cwd: cwd, env: listingEnv)
        }
        return environment(
            profile: profile, base: base, access: .read(filterDrivers: listed.filters, diffDrivers: listed.diffs))
    }

    /// The filter driver names (`filter.<name>.*`) and diff driver names (`diff.<name>.*`) of every config
    /// scope git reads in `cwd`, including includes and the worktree's `config.worktree`, from one listing.
    /// `git config` itself runs nothing. Any git failure but "no match" (exit 1) throws, so a read never runs
    /// without its overrides.
    public static func drivers(runner: GitRunner, cwd: URL, env: [String: String]) async throws
        -> (filters: [String], diffs: [String])
    {
        let result = try await runner.run(
            ["config", "-z", "--name-only", "--get-regexp", #"^(filter|diff)\."#], cwd: cwd, env: env,
            timeout: .seconds(10), allowedExitCodes: [0, 1])
        return try drivers(in: result.stdout.split(separator: 0))
    }

    /// The filter and diff driver names among the config `keys` git listed. The names come from the repo, so they
    /// are parsed as bytes (no Unicode normalization or grapheme merging) and a name that is not valid UTF-8 (which
    /// no environment string can carry) throws. Two-part keys such as `diff.external` name no driver and are
    /// skipped.
    static func drivers(in keys: [Data.SubSequence]) throws -> (filters: [String], diffs: [String]) {
        try (subsections(of: "filter", in: keys, notUTF8: .filterDriverNotUTF8),
             subsections(of: "diff", in: keys, notUTF8: .diffDriverNotUTF8))
    }

    public enum ReadSafetyError: Error, Equatable, Sendable {
        /// The config names a filter driver whose name is not valid UTF-8, so it cannot be disabled.
        case filterDriverNotUTF8
        /// The config names a diff driver whose name is not valid UTF-8, so it cannot be disabled.
        case diffDriverNotUTF8
        /// The user's config has a credential helper entry that is not valid UTF-8, so it cannot be passed on.
        case credentialHelperNotUTF8
        /// `git config --show-origin --list` printed something that is not `<origin>\0<key>[\n<value>]\0` records,
        /// so its driver names cannot be trusted.
        case configListingMalformed
    }

    /// The subsection names of `section` (`<section>.<name>.<variable>` keys) among the listed `keys`.
    private static func subsections(of section: String, in keys: [Data.SubSequence], notUTF8: ReadSafetyError)
        throws -> [String]
    {
        let prefix = Array("\(section).".utf8)
        var names: [String] = []
        for key in keys {
            // `<section>.<name>.<variable>`: the name is everything between the first and the last dot.
            guard key.starts(with: prefix), let lastDot = key.lastIndex(of: UInt8(ascii: ".")) else { continue }
            let start = key.startIndex + prefix.count
            guard start < lastDot else { continue }
            guard let name = String(validating: key[start..<lastDot], as: UTF8.self) else { throw notUTF8 }
            names.append(name)
        }
        return names
    }

    /// `ssh -o BatchMode=yes`, plus `-i '<path>' -o IdentitiesOnly=yes` for a key file. Git runs it with
    /// `/bin/sh -c`, so the path is single-quoted.
    static func sshCommand(_ key: Profile.SSHKey) -> String {
        switch key {
        case .agent: "ssh -o BatchMode=yes"
        case .keyFile(let path): "ssh -o BatchMode=yes -i \(shellQuoted(path)) -o IdentitiesOnly=yes"
        }
    }

    /// POSIX single quoting: `'` becomes `'\''`.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacing("'", with: "'\\''") + "'"
    }

    /// `author.*` and `committer.*` too: a repo's own `author.name` would otherwise beat `user.name`.
    private static func identityConfig(_ profile: Profile) -> [(String, String)] {
        let name = profile.identity.name
        let email = profile.identity.email
        return [("user.name", name), ("user.email", email), ("author.name", name), ("author.email", email),
                ("committer.name", name), ("committer.email", email)]
    }

    /// A signing method without a key (`Signing.isUsable` false) signs nothing, as `.none`: never an empty
    /// `user.signingKey`.
    private static func signingConfig(_ profile: Profile) -> [(String, String)] {
        guard profile.signing.isUsable else { return [("commit.gpgSign", "false")] }
        switch profile.signing {
        case .none:
            return [("commit.gpgSign", "false")]
        case .gpg(let keyID):
            return [("gpg.format", "openpgp"), ("user.signingKey", keyID),
                    ("commit.gpgSign", profile.signByDefault ? "true" : "false")]
        case .ssh(let keyPath):
            return [("gpg.format", "ssh"), ("user.signingKey", keyPath),
                    ("commit.gpgSign", profile.signByDefault ? "true" : "false")]
        }
    }

    private static let readSafetyConfig: [(String, String)] = [
        ("core.fsmonitor", "false"),
        ("log.showSignature", "false"),
        ("diff.submodule", "short"),
        ("diff.autoRefreshIndex", "false"),
        ("core.hooksPath", "/dev/null"),
        ("diff.external", ""),
        ("i18n.logOutputEncoding", "UTF-8"),
    ]

    /// `core.alternateRefsCommand` runs while a fetch looks at a repo's alternates (`objects/info/alternates`,
    /// which a downloaded repo brings along): `true` lists no alternate ref. A submodule fetch would run in a
    /// nested repo with config of its own, and a background fetch has no use for it.
    private static let backgroundFetchConfig: [(String, String)] = [
        ("core.hooksPath", "/dev/null"),
        ("core.fsmonitor", "false"),
        ("core.alternateRefsCommand", "true"),
        ("fetch.recurseSubmodules", "false"),
        ("http.saveCookies", "false"),
        ("gc.auto", "0"),
        ("maintenance.auto", "false"),
    ]

    /// The `.network` block of every token-carrying command (its hooks are set by kind): the background fetch's,
    /// plus no submodule recursion on a push, and redirects followed only on a command's first request (git's
    /// default, set in case the user's config allows more), so a later response cannot move it to another URL.
    private static let tokenNetworkConfig: [(String, String)] = [
        ("core.fsmonitor", "false"),
        ("core.alternateRefsCommand", "true"),
        ("fetch.recurseSubmodules", "false"),
        ("push.recurseSubmodules", "no"),
        ("submodule.recurse", "false"),
        ("http.saveCookies", "false"),
        ("http.followRedirects", "initial"),
        ("gc.auto", "0"),
        ("maintenance.auto", "false"),
    ]

    private static func append(_ config: [(String, String)], to env: inout [String: String]) {
        var index = Int(env["GIT_CONFIG_COUNT"] ?? "") ?? 0
        for (key, value) in config {
            env["GIT_CONFIG_KEY_\(index)"] = key
            env["GIT_CONFIG_VALUE_\(index)"] = value
            index += 1
        }
        if index > 0 { env["GIT_CONFIG_COUNT"] = String(index) }
    }
}

/// One account's token for git over https on `host` (see `GitInvocation`). Its description and mirror never show the
/// token, so a log, `dump` or test failure that prints it leaks nothing.
public struct GitCredential: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    public var kind: HostingKind
    /// The host as the account has it, `HostingHTTP.validatedHost` style (with a port if it has one).
    public var host: String
    /// The username git sends with the token for kinds that need one; it must pass `isSafeUsername(_:)`, else the
    /// credential is never used.
    public var username: String
    public var token: String

    public init(kind: HostingKind, host: String, username: String, token: String) {
        self.kind = kind
        self.host = host
        self.username = username
        self.token = token
    }

    /// What the token helper answers as the username: GitHub's `x-access-token`, whatever `username` says.
    var gitUsername: String {
        switch kind {
        case .github: "x-access-token"
        }
    }

    /// Printable ASCII without a space, `:`, `@`, `/`, quote, `$`, backslash or backquote, and not empty: nothing a
    /// shell, a URL or the credential protocol could read as more than a name.
    static func isSafeUsername(_ username: String) -> Bool {
        !username.isEmpty && username.unicodeScalars.allSatisfy {
            (0x21...0x7E).contains($0.value) && !":@/'\"$\\`".unicodeScalars.contains($0)
        }
    }

    public var description: String { "GitCredential(\(kind), \(host), \(username), token: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["kind": kind, "host": host, "username": username, "token": "<redacted>"])
    }
}
