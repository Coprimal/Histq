// Builds the complete environment of a git child process (GitRunner inherits nothing): the profile is injected as
// command-scope config (`GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n`, which beats `.git/config`) and
// `GIT_SSH_COMMAND`, and git never prompts.
//
// Reads (status, log, diff, show, for-each-ref, watcher refreshes) also get a safety block, because a downloaded
// repo's `.git/config`, `.git/info/attributes` and hooks could otherwise make an automatic read run a command: no
// fsmonitor hook, no signature check (`gpg.program`), no inline submodule diff (a child `git diff` without
// `--no-ext-diff`), no index refresh write, no hooks, no external diff (`diff.external`), every filter driver and
// every diff driver (`textconv`, `command`) configured where the read runs disabled (an empty command: git fails to
// run it, so a read that does not pass `--no-ext-diff --no-textconv` fails instead of running it), no transport at
// all (`GIT_ALLOW_PROTOCOL` empty, which beats the repo's `protocol.<name>.allow`, and `GIT_NO_LAZY_FETCH` on
// git >= 2.44), so a partial clone's promisor remote never fetches through its `uploadpack` or `core.sshCommand`, and
// UTF-8 log output (a repo's `i18n.logOutputEncoding` such as UTF-16 would put NUL bytes in the NUL-terminated log
// records). Writes (user actions) keep the normal behavior, so git-lfs and hooks work.
//
// Only reads and writes are here (GitInvocation.swift's read/write parts); the network accesses (token-carrying
// commands, background fetch) and their credentials come with the network milestone. A credential variable in the
// base is still dropped, so no read or write ever carries one. Neither access sets GIT_ASKPASS or SSH_ASKPASS (as on
// the Mac): GIT_TERMINAL_PROMPT=0 and ssh's BatchMode keep them from prompting.
//
// Windows forms (roadmap "POSIX git strings"): the base environment keeps the system variables a Windows process needs
// and HOME is %USERPROFILE%; `core.hooksPath` is NUL (see NoHooksPath); the ssh command is still run by git's sh, so
// a key path is single-quoted in C:/ form.
using System.Globalization;
using System.Text;

namespace Histq.Core;

public static class GitInvocation
{
    /// <summary>What a git command may do: a user action (<see cref="Write"/>) or an automatic read.</summary>
    public abstract record Access
    {
        private Access()
        {
        }

        /// <summary>A user action: the repo's hooks, filters and helpers run as with the git CLI.</summary>
        public static Access Write { get; } = new WriteAccess();

        /// <summary>
        /// An automatic read in a folder whose config names <paramref name="filterDrivers"/> and
        /// <paramref name="diffDrivers"/> (see <see cref="DriversAsync"/>).
        /// </summary>
        public static Access Read(IReadOnlyList<string> filterDrivers, IReadOnlyList<string>? diffDrivers = null) =>
            new ReadAccess(filterDrivers, diffDrivers ?? []);

        public sealed record WriteAccess : Access;

        public sealed record ReadAccess(IReadOnlyList<string> FilterDrivers, IReadOnlyList<string> DiffDrivers) : Access
        {
            public bool Equals(ReadAccess? other) =>
                other is not null
                && FilterDrivers.SequenceEqual(other.FilterDrivers, StringComparer.Ordinal)
                && DiffDrivers.SequenceEqual(other.DiffDrivers, StringComparer.Ordinal);

            public override int GetHashCode() => HashCode.Combine(FilterDrivers.Count, DiffDrivers.Count);
        }
    }

    /// <summary>Why a read environment cannot be built.</summary>
    public enum ReadSafetyErrorKind
    {
        /// <summary>The config names a filter driver whose name is not valid UTF-8, so it cannot be disabled.</summary>
        FilterDriverNotUTF8,

        /// <summary>The config names a diff driver whose name is not valid UTF-8, so it cannot be disabled.</summary>
        DiffDriverNotUTF8,

        /// <summary>
        /// <c>git config --show-origin --list</c> printed something that is not <c>&lt;origin&gt;\0&lt;key&gt;[\n&lt;value&gt;]\0</c>
        /// records, so its driver names cannot be trusted.
        /// </summary>
        ConfigListingMalformed,
    }

    /// <summary>A read that must not run: its overrides could not be built.</summary>
    public sealed class ReadSafetyError(ReadSafetyErrorKind kind) : Exception(MessageFor(kind)), IEquatable<ReadSafetyError>
    {
        public ReadSafetyErrorKind Kind { get; } = kind;

        public bool Equals(ReadSafetyError? other) => other is not null && Kind == other.Kind;

        public override bool Equals(object? obj) => Equals(obj as ReadSafetyError);

        public override int GetHashCode() => Kind.GetHashCode();

        private static string MessageFor(ReadSafetyErrorKind kind) => kind switch
        {
            ReadSafetyErrorKind.FilterDriverNotUTF8 => "The repository names a filter driver that is not valid UTF-8.",
            ReadSafetyErrorKind.DiffDriverNotUTF8 => "The repository names a diff driver that is not valid UTF-8.",
            _ => "The git config listing is malformed.",
        };
    }

    /// <summary>
    /// The <c>core.hooksPath</c> of reads, a path where no hook can be: the null device (<c>NUL</c> on Windows,
    /// <c>/dev/null</c> elsewhere). The one place to change it if the Windows probe shows NUL does not keep hooks off
    /// (fallback: an empty app-owned folder, <c>%LOCALAPPDATA%\HistqData\no-hooks</c>).
    /// </summary>
    public static string NoHooksPath { get; } = OperatingSystem.IsWindows() ? "NUL" : "/dev/null";

    /// <summary>The program of <c>GIT_SSH_COMMAND</c>, found on git's PATH.</summary>
    internal const string SshProgram = "ssh";

    /// <summary>The variables the Mac base environment inherits: the user and the ssh and gpg agents.</summary>
    internal static readonly string[] PosixInheritedKeys = ["USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK", "GNUPGHOME"];

    /// <summary>
    /// The variables the Windows base environment inherits: what a process needs to start and find its folders
    /// (git.exe, its sh and ssh), and the ssh and gpg agents.
    /// </summary>
    internal static readonly string[] WindowsInheritedKeys =
    [
        "SystemRoot", "windir", "ComSpec", "PATHEXT", "TEMP", "TMP", "USERPROFILE", "APPDATA", "LOCALAPPDATA",
        "HOMEDRIVE", "HOMEPATH", "ProgramData", "SSH_AUTH_SOCK", "GNUPGHOME",
    ];

    /// <summary>
    /// The base every invocation starts from: PATH, HOME and the few inherited variables processes need. Off Windows
    /// (as on the Mac) PATH is <paramref name="path"/>, by default the fixed <see cref="GitExecutable.FixedPath"/>, and
    /// HOME is <paramref name="home"/>, by default the user's home folder. On Windows see
    /// <see cref="WindowsBaseEnvironment"/>. <paramref name="inherited"/> is this process's environment by default.
    /// </summary>
    /// <param name="gitExecutable">The absolute path of the git that runs (Windows only: its folder joins PATH).</param>
    public static Dictionary<string, string> BaseEnvironment(
        string? path = null, string? home = null, IReadOnlyDictionary<string, string>? inherited = null,
        string? gitExecutable = null)
    {
        inherited ??= ProcessEnvironment();
        return OperatingSystem.IsWindows()
            ? WindowsBaseEnvironment(path, home, inherited, gitExecutable)
            : PosixBaseEnvironment(
                path ?? GitExecutable.FixedPath,
                home ?? System.Environment.GetFolderPath(System.Environment.SpecialFolder.UserProfile), inherited);
    }

    /// <summary>The Mac base environment: PATH, HOME and <see cref="PosixInheritedKeys"/> when inherited.</summary>
    internal static Dictionary<string, string> PosixBaseEnvironment(
        string path, string home, IReadOnlyDictionary<string, string> inherited)
    {
        var env = new Dictionary<string, string>(GitRunner.EnvironmentKeyComparer) { ["PATH"] = path, ["HOME"] = home };
        foreach (var key in PosixInheritedKeys)
        {
            if (inherited.TryGetValue(key, out var value))
            {
                env[key] = value;
            }
        }

        return env;
    }

    /// <summary>
    /// The Windows base environment (pure string work, so it runs on any OS): <see cref="WindowsInheritedKeys"/> when
    /// inherited (names matched case-insensitively, as Windows does), HOME as <paramref name="home"/>, else the
    /// inherited USERPROFILE, else the user's profile folder; PATH as <paramref name="path"/>, else the inherited PATH,
    /// with the folder of <paramref name="gitExecutable"/> added at the end unless it is already in it.
    /// </summary>
    internal static Dictionary<string, string> WindowsBaseEnvironment(
        string? path, string? home, IReadOnlyDictionary<string, string> inherited, string? gitExecutable)
    {
        var env = new Dictionary<string, string>(GitRunner.EnvironmentKeyComparer);
        foreach (var key in WindowsInheritedKeys)
        {
            if (LookupIgnoringCase(inherited, key) is { } value)
            {
                env[key] = value;
            }
        }

        env["HOME"] = home
                      ?? LookupIgnoringCase(inherited, "USERPROFILE")
                      ?? System.Environment.GetFolderPath(System.Environment.SpecialFolder.UserProfile);
        var searchPath = path ?? LookupIgnoringCase(inherited, "PATH") ?? "";
        var gitFolder = WindowsFolder(gitExecutable);
        if (!string.IsNullOrEmpty(gitFolder) && !ContainsFolder(searchPath, gitFolder))
        {
            searchPath = searchPath.Length == 0 ? gitFolder : searchPath.TrimEnd(';') + ";" + gitFolder;
        }

        env["PATH"] = searchPath;
        return env;
    }

    /// <summary>
    /// <paramref name="base"/> plus the profile and, for reads, their safety block. Config entries are appended after
    /// any <c>GIT_CONFIG_*</c> entries already in <paramref name="base"/>; within command scope the last one wins. A
    /// credential variable in <paramref name="base"/> is dropped: no read or write may carry a token.
    /// </summary>
    public static Dictionary<string, string> Environment(
        Profile? profile, IReadOnlyDictionary<string, string> @base, Access? access = null)
    {
        access ??= Access.Write;
        var env = new Dictionary<string, string>(GitRunner.EnvironmentKeyComparer);
        foreach (var (key, value) in @base)
        {
            if (!IsCredentialVariable(key))
            {
                env[key] = value;
            }
        }

        env["GIT_TERMINAL_PROMPT"] = "0";
        env["LC_ALL"] = "C";
        var config = new List<(string Key, string Value)>();
        if (profile is not null)
        {
            config.AddRange(IdentityConfig(profile));
            config.AddRange(SigningConfig(profile));
        }

        env["GIT_SSH_COMMAND"] = SshCommand(profile?.Ssh ?? new ProfileSshKey.Agent());
        if (access is Access.ReadAccess read)
        {
            env["GIT_OPTIONAL_LOCKS"] = "0";
            env["GIT_NO_LAZY_FETCH"] = "1";
            // An empty allow list: no transport (`file`, `ssh`, `ext`, remote helpers...) may run.
            env["GIT_ALLOW_PROTOCOL"] = "";
            config.AddRange(ReadSafetyConfig);
            foreach (var driver in read.FilterDrivers)
            {
                var section = "filter." + driver;
                config.Add((section + ".clean", ""));
                config.Add((section + ".smudge", ""));
                config.Add((section + ".process", ""));
                config.Add((section + ".required", "false"));
            }

            foreach (var driver in read.DiffDrivers)
            {
                config.Add(("diff." + driver + ".textconv", ""));
                config.Add(("diff." + driver + ".command", ""));
            }
        }

        Append(config, env);
        return env;
    }

    /// <summary>
    /// A variable that carries a credential (<c>HISTQ_GIT_TOKEN</c>, <c>HISTQ_GIT_TOKEN_&lt;n&gt;</c>,
    /// <c>HISTQ_GIT_USER_&lt;n&gt;</c>), which only the token helpers may set. Case-insensitive on Windows, where
    /// variable names are.
    /// </summary>
    internal static bool IsCredentialVariable(string key)
    {
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        return key.StartsWith("HISTQ_GIT_TOKEN", comparison) || key.StartsWith("HISTQ_GIT_USER_", comparison);
    }

    /// <summary>
    /// The read environment for a read run in <paramref name="cwd"/>: lists the filter and diff drivers configured
    /// there first (one listing), or takes them from <paramref name="cache"/> while none of the files that listing read
    /// has changed (see <see cref="ReadEnvironmentCache"/>).
    /// </summary>
    public static async Task<Dictionary<string, string>> ReadEnvironmentAsync(
        Profile? profile, IReadOnlyDictionary<string, string> @base, GitRunner runner, string cwd,
        ReadEnvironmentCache? cache = null, CancellationToken ct = default)
    {
        var listingEnv = Environment(profile, @base, Access.Read([]));
        var listed = cache is null
            ? await DriversAsync(runner, cwd, listingEnv, ct).ConfigureAwait(false)
            : await cache.DriversAsync(runner, cwd, listingEnv, ct).ConfigureAwait(false);
        return Environment(profile, @base, Access.Read(listed.Filters, listed.Diffs));
    }

    /// <summary>
    /// The filter driver names (<c>filter.&lt;name&gt;.*</c>) and diff driver names (<c>diff.&lt;name&gt;.*</c>) of
    /// every config scope git reads in <paramref name="cwd"/>, including includes and the worktree's
    /// <c>config.worktree</c>, from one listing. <c>git config</c> itself runs nothing. Any git failure but "no match"
    /// (exit 1) throws, so a read never runs without its overrides.
    /// </summary>
    public static async Task<(IReadOnlyList<string> Filters, IReadOnlyList<string> Diffs)> DriversAsync(
        GitRunner runner, string cwd, IReadOnlyDictionary<string, string> env, CancellationToken ct = default)
    {
        var result = await runner.RunAsync(
            ["config", "-z", "--name-only", "--get-regexp", @"^(filter|diff)\."], cwd, env,
            timeout: TimeSpan.FromSeconds(10), allowedExitCodes: [0, 1], ct: ct).ConfigureAwait(false);
        return Drivers(SplitOnNul(result.Stdout));
    }

    /// <summary>
    /// The filter and diff driver names among the config <paramref name="keys"/> git listed. The names come from the
    /// repo, so they are parsed as bytes (no Unicode normalization) and a name that is not valid UTF-8 (which no
    /// environment string can carry) throws. Two-part keys such as <c>diff.external</c> name no driver and are skipped.
    /// </summary>
    internal static (IReadOnlyList<string> Filters, IReadOnlyList<string> Diffs) Drivers(
        IReadOnlyList<ReadOnlyMemory<byte>> keys) =>
        (Subsections("filter", keys, ReadSafetyErrorKind.FilterDriverNotUTF8),
         Subsections("diff", keys, ReadSafetyErrorKind.DiffDriverNotUTF8));

    /// <summary>The subsection names of <paramref name="section"/> (<c>&lt;section&gt;.&lt;name&gt;.&lt;variable&gt;</c> keys).</summary>
    private static List<string> Subsections(
        string section, IReadOnlyList<ReadOnlyMemory<byte>> keys, ReadSafetyErrorKind notUTF8)
    {
        var prefix = Encoding.ASCII.GetBytes(section + ".");
        var names = new List<string>();
        foreach (var key in keys)
        {
            var bytes = key.Span;
            // `<section>.<name>.<variable>`: the name is everything between the first and the last dot.
            var lastDot = bytes.LastIndexOf((byte)'.');
            if (!bytes.StartsWith(prefix) || lastDot < 0 || prefix.Length >= lastDot)
            {
                continue;
            }

            names.Add(DecodeUTF8(bytes[prefix.Length..lastDot]) ?? throw new ReadSafetyError(notUTF8));
        }

        return names;
    }

    /// <summary>
    /// <c>ssh -o BatchMode=yes</c>, plus <c>-i '&lt;path&gt;' -o IdentitiesOnly=yes</c> for a key file. Git runs it
    /// with its sh (<c>/bin/sh -c</c>, Git for Windows' own sh on Windows), so the path is single-quoted, and on
    /// Windows written with forward slashes (<c>C:/Users/...</c>): a backslash is a legal file name character
    /// elsewhere, so only Windows converts it.
    /// </summary>
    internal static string SshCommand(ProfileSshKey key) => key switch
    {
        ProfileSshKey.KeyFile file =>
            $"{SshProgram} -o BatchMode=yes -i {ShellQuoted(ShellPath(file.Path))} -o IdentitiesOnly=yes",
        _ => $"{SshProgram} -o BatchMode=yes",
    };

    /// <summary><paramref name="path"/> as git's sh takes it: <c>C:/...</c> on Windows, unchanged elsewhere.</summary>
    internal static string ShellPath(string path) => OperatingSystem.IsWindows() ? path.Replace('\\', '/') : path;

    /// <summary>POSIX single quoting: <c>'</c> becomes <c>'\''</c>.</summary>
    internal static string ShellQuoted(string text) =>
        "'" + text.Replace("'", @"'\''", StringComparison.Ordinal) + "'";

    /// <summary>
    /// <c>author.*</c> and <c>committer.*</c> too: a repo's own <c>author.name</c> would otherwise beat
    /// <c>user.name</c>. An empty (or blank) name or email is left out, so git uses the user's own config for it:
    /// never an empty ident.
    /// </summary>
    private static List<(string, string)> IdentityConfig(Profile profile)
    {
        var name = profile.Identity.Name;
        var email = profile.Identity.Email;
        var hasName = !string.IsNullOrWhiteSpace(name);
        var hasEmail = !string.IsNullOrWhiteSpace(email);
        var config = new List<(string, string)>();
        foreach (var scope in new[] { "user", "author", "committer" })
        {
            if (hasName)
            {
                config.Add((scope + ".name", name));
            }

            if (hasEmail)
            {
                config.Add((scope + ".email", email));
            }
        }

        return config;
    }

    /// <summary>
    /// A signing method without a key (<see cref="ProfileSigning.IsUsable"/> false) signs nothing, as
    /// <see cref="ProfileSigning.None"/>: never an empty <c>user.signingKey</c>.
    /// </summary>
    private static List<(string, string)> SigningConfig(Profile profile)
    {
        var sign = profile.SignByDefault ? "true" : "false";
        return profile.Signing switch
        {
            _ when !profile.Signing.IsUsable => [("commit.gpgSign", "false")],
            ProfileSigning.Gpg gpg => [("gpg.format", "openpgp"), ("user.signingKey", gpg.KeyID), ("commit.gpgSign", sign)],
            ProfileSigning.Ssh ssh => [("gpg.format", "ssh"), ("user.signingKey", ssh.KeyPath), ("commit.gpgSign", sign)],
            _ => [("commit.gpgSign", "false")],
        };
    }

    private static IReadOnlyList<(string, string)> ReadSafetyConfig { get; } =
    [
        ("core.fsmonitor", "false"),
        ("log.showSignature", "false"),
        ("diff.submodule", "short"),
        ("diff.autoRefreshIndex", "false"),
        ("core.hooksPath", NoHooksPath),
        ("diff.external", ""),
        ("i18n.logOutputEncoding", "UTF-8"),
    ];

    private static void Append(List<(string Key, string Value)> config, Dictionary<string, string> env)
    {
        var index = env.TryGetValue("GIT_CONFIG_COUNT", out var count)
                    && int.TryParse(count, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var parsed)
            ? parsed
            : 0;
        foreach (var (key, value) in config)
        {
            env[string.Create(CultureInfo.InvariantCulture, $"GIT_CONFIG_KEY_{index}")] = key;
            env[string.Create(CultureInfo.InvariantCulture, $"GIT_CONFIG_VALUE_{index}")] = value;
            index++;
        }

        if (index > 0)
        {
            env["GIT_CONFIG_COUNT"] = index.ToString(CultureInfo.InvariantCulture);
        }
    }

    // Helpers shared with ReadEnvironmentCache.

    private static readonly UTF8Encoding StrictUTF8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    /// <summary><paramref name="bytes"/> as text when they are valid UTF-8, else null (never a replacement character).</summary>
    internal static string? DecodeUTF8(ReadOnlySpan<byte> bytes)
    {
        try
        {
            return StrictUTF8.GetString(bytes);
        }
        catch (DecoderFallbackException)
        {
            return null;
        }
    }

    /// <summary>The NUL-separated fields of <paramref name="data"/>, empty ones dropped.</summary>
    internal static List<ReadOnlyMemory<byte>> SplitOnNul(byte[] data)
    {
        var fields = new List<ReadOnlyMemory<byte>>();
        var start = 0;
        for (var i = 0; i <= data.Length; i++)
        {
            if (i == data.Length || data[i] == 0)
            {
                if (i > start)
                {
                    fields.Add(data.AsMemory(start, i - start));
                }

                start = i + 1;
            }
        }

        return fields;
    }

    /// <summary>This process's environment, keyed as GitRunner keys it.</summary>
    private static Dictionary<string, string> ProcessEnvironment()
    {
        var env = new Dictionary<string, string>(GitRunner.EnvironmentKeyComparer);
        foreach (System.Collections.DictionaryEntry entry in System.Environment.GetEnvironmentVariables())
        {
            if (entry.Key is string key && entry.Value is string value)
            {
                env[key] = value;
            }
        }

        return env;
    }

    /// <summary>The value of <paramref name="key"/> in <paramref name="variables"/>, its name matched case-insensitively.</summary>
    private static string? LookupIgnoringCase(IReadOnlyDictionary<string, string> variables, string key)
    {
        if (variables.TryGetValue(key, out var exact))
        {
            return exact;
        }

        foreach (var (name, value) in variables)
        {
            if (string.Equals(name, key, StringComparison.OrdinalIgnoreCase))
            {
                return value;
            }
        }

        return null;
    }

    /// <summary>
    /// The folder of the Windows path <paramref name="file"/> (either separator, so it also works off Windows); null
    /// when it has none.
    /// </summary>
    private static string? WindowsFolder(string? file)
    {
        var cut = file?.LastIndexOfAny(['\\', '/']) ?? -1;
        if (file is null || cut <= 0)
        {
            return null;
        }

        // `C:\git.exe` is in `C:\`, not in the drive-relative `C:`.
        return file[cut - 1] == ':' ? file[..(cut + 1)] : file[..cut];
    }

    /// <summary>Whether the <c>;</c>-separated <paramref name="searchPath"/> lists <paramref name="folder"/> (Windows rules).</summary>
    private static bool ContainsFolder(string searchPath, string folder)
    {
        var wanted = folder.TrimEnd('\\', '/');
        foreach (var entry in searchPath.Split(';'))
        {
            if (string.Equals(entry.Trim().Trim('"').TrimEnd('\\', '/'), wanted, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }
}
