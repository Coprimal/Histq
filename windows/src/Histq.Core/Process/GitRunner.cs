// Runs git as a child process: an argument list (never a shell), stdout and stderr drained concurrently as raw bytes,
// a bounded stderr tail, cancellation that kills the whole process tree (Windows has no SIGINT for a child), optional
// timeouts and a serialized lane for writes.
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Text;
using System.Threading.Channels;

namespace Histq.Core;

/// <summary>The outcome of a git command that exited with an allowed code.</summary>
public sealed class GitResult(int exitCode, byte[] stdout, string stderrTail)
{
    public int ExitCode { get; } = exitCode;

    /// <summary>Everything the command wrote to stdout.</summary>
    public byte[] Stdout { get; } = stdout;

    /// <summary>The last 8 KB of stderr.</summary>
    public string StderrTail { get; } = stderrTail;

    /// <summary><see cref="Stdout"/> decoded as UTF-8 (invalid bytes replaced).</summary>
    public string Text => Encoding.UTF8.GetString(Stdout);
}

/// <summary>The cases of <see cref="GitError"/>.</summary>
public enum GitErrorKind
{
    Auth,
    HostKey,
    NonFastForward,
    Conflict,
    IndexLock,

    /// <summary>The command ran longer than the timeout it was given.</summary>
    Timeout,
    Other,

    /// <summary>The executable could not be started.</summary>
    LaunchFailed,

    /// <summary>An auto-stash could not be put back cleanly: the changes are kept in the stash <see cref="GitError.StashHash"/>.</summary>
    AutostashKept,
}

/// <summary>
/// Why a git command failed. Every kind but <see cref="GitErrorKind.Timeout"/>, <see cref="GitErrorKind.LaunchFailed"/>
/// and <see cref="GitErrorKind.AutostashKept"/> carries the exit code and the last 8 KB of stderr. Equal when the kind,
/// exit code and stderr tail are equal.
/// </summary>
public sealed class GitError : Exception, IEquatable<GitError>
{
    private readonly string _detail;

    private GitError(GitErrorKind kind, int? exitCode, string detail, string message)
        : base(message)
    {
        Kind = kind;
        ExitCode = exitCode;
        _detail = detail;
    }

    public GitErrorKind Kind { get; }

    /// <summary>The exit code (128 + the signal number off Windows when a signal killed git); null for the kinds without one.</summary>
    public int? ExitCode { get; }

    /// <summary>The stderr tail; for <see cref="GitErrorKind.LaunchFailed"/> the launch error, for
    /// <see cref="GitErrorKind.AutostashKept"/> a sentence naming the stash.</summary>
    public string StderrTail => Kind switch
    {
        GitErrorKind.Timeout => "",
        GitErrorKind.AutostashKept => Message,
        _ => _detail,
    };

    /// <summary>The stash commit hash of <see cref="GitErrorKind.AutostashKept"/>, else null.</summary>
    public string? StashHash => Kind == GitErrorKind.AutostashKept ? _detail : null;

    public static GitError Auth(int exit, string stderrTail) => WithExit(GitErrorKind.Auth, exit, stderrTail);

    public static GitError HostKey(int exit, string stderrTail) => WithExit(GitErrorKind.HostKey, exit, stderrTail);

    public static GitError NonFastForward(int exit, string stderrTail) =>
        WithExit(GitErrorKind.NonFastForward, exit, stderrTail);

    public static GitError Conflict(int exit, string stderrTail) => WithExit(GitErrorKind.Conflict, exit, stderrTail);

    public static GitError IndexLock(int exit, string stderrTail) => WithExit(GitErrorKind.IndexLock, exit, stderrTail);

    public static GitError Timeout() => new(GitErrorKind.Timeout, null, "", "git timed out.");

    public static GitError Other(int exit, string stderrTail) => WithExit(GitErrorKind.Other, exit, stderrTail);

    public static GitError LaunchFailed(string message) => new(GitErrorKind.LaunchFailed, null, message, message);

    public static GitError AutostashKept(string hash) =>
        new(GitErrorKind.AutostashKept, null, hash, $"Changes kept in stash {hash[..Math.Min(7, hash.Length)]}.");

    private static GitError WithExit(GitErrorKind kind, int exit, string stderrTail) =>
        new(kind, exit, stderrTail, $"git exited with code {exit}.");

    /// <summary>
    /// Classifies a failed command from its stderr tail and the end of its stdout (merge, rebase and stash report
    /// <c>CONFLICT (...)</c> on stdout).
    /// </summary>
    internal static GitError Classify(int exit, string stderrTail, string stdoutTail)
    {
        var err = stderrTail.ToLowerInvariant();
        var all = err + "\n" + stdoutTail.ToLowerInvariant();
        static bool Has(string[] needles, string text) =>
            needles.Any(needle => text.Contains(needle, StringComparison.Ordinal));

        if (Has(["host key verification failed", "remote host identification has changed", "no matching host key"], err))
        {
            return HostKey(exit, stderrTail);
        }

        if (err.Contains("index.lock", StringComparison.Ordinal) && err.Contains("file exists", StringComparison.Ordinal))
        {
            return IndexLock(exit, stderrTail);
        }

        if (Has(["non-fast-forward", "[rejected]", "updates were rejected", "not possible to fast-forward",
                "diverging branches can't be fast-forwarded"], err))
        {
            return NonFastForward(exit, stderrTail);
        }

        if (Has(["conflict (", "automatic merge failed", "could not apply", "unmerged files", "unmerged paths",
                "needs merge"], all))
        {
            return Conflict(exit, stderrTail);
        }

        if (Has(["permission denied (publickey", "authentication failed", "could not read username",
                "could not read password", "terminal prompts disabled", "invalid username or password"], err))
        {
            return Auth(exit, stderrTail);
        }

        return Other(exit, stderrTail);
    }

    public bool Equals(GitError? other) =>
        other is not null && Kind == other.Kind && ExitCode == other.ExitCode
        && string.Equals(_detail, other._detail, StringComparison.Ordinal);

    public override bool Equals(object? obj) => Equals(obj as GitError);

    public override int GetHashCode() => HashCode.Combine(Kind, ExitCode, StringComparer.Ordinal.GetHashCode(_detail));
}

/// <summary>
/// Runs git commands for one repository. <c>env</c> is always the complete child environment (nothing is inherited
/// from the app), so callers build it with GitInvocation; on Windows its keys are case-insensitive
/// (<see cref="EnvironmentKeyComparer"/>) and two keys that differ only in case fail the launch.
/// </summary>
public sealed class GitRunner
{
    public enum LineSource
    {
        Stdout,
        Stderr,
    }

    /// <summary>
    /// One line of output. Stdout is split on the stream's delimiter (empty lines kept); stderr is split on <c>\n</c>
    /// and <c>\r</c> (progress output), empty lines dropped. <see cref="Truncated"/>: the line was longer than the
    /// stream's <c>maxLineBytes</c>, <see cref="Text"/> is its start and the rest was dropped.
    /// </summary>
    public readonly record struct Line(LineSource Source, string Text, bool Truncated = false);

    /// <summary>
    /// Timing hook (set once at launch in debug and HISTQ_PERF builds, before any process runs): called once per
    /// finished child process with its verb (the first argument after leading <c>-c &lt;key=value&gt;</c>,
    /// <c>-C &lt;dir&gt;</c> and <c>--option</c> arguments), its wall time in ms, its folder's name, its exit code and
    /// the signal that ended it (always null here: .NET reports no signal). Null in shipped builds.
    /// </summary>
    public static Action<string, double, string, int, int?>? ProcessObserver { get; set; }

    /// <summary>The comparer of environment keys: case-insensitive on Windows, as the OS treats them.</summary>
    public static StringComparer EnvironmentKeyComparer { get; } =
        OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;

    /// <summary>The lane of <see cref="MutateAsync{T}"/>: one write at a time, in call order.</summary>
    private readonly SemaphoreSlim _lane = new(1, 1);

    private readonly Action<Process>? _onStarted;

    /// <param name="executable">The absolute path of git (<see cref="GitExecutable.ExecutablePath"/>).</param>
    /// <param name="onStarted">Called with each git process right after it starts (the App attaches it to its job
    /// object, so git dies with Histq). It must not wait for the process. When it throws, the process tree is killed
    /// and the command fails with <see cref="GitErrorKind.LaunchFailed"/>.</param>
    public GitRunner(string executable, Action<Process>? onStarted = null)
    {
        Executable = executable;
        _onStarted = onStarted;
    }

    public string Executable { get; }

    /// <summary>
    /// Runs <c>git &lt;args&gt;</c> in <paramref name="cwd"/> to completion. Throws <see cref="GitError"/> unless it
    /// exits with one of <paramref name="allowedExitCodes"/> (<c>[0]</c> by default), <see cref="GitErrorKind.Timeout"/>
    /// once <paramref name="timeout"/> passes (git is then killed), and <see cref="OperationCanceledException"/> when
    /// <paramref name="ct"/> is cancelled (git's process tree is killed first).
    /// </summary>
    public async Task<GitResult> RunAsync(
        IReadOnlyList<string> args, string cwd, IReadOnlyDictionary<string, string> env, byte[]? stdin = null,
        TimeSpan? timeout = null, IReadOnlyCollection<int>? allowedExitCodes = null, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        var child = new ChildProcess(Executable, args, cwd, env, stdin, timeout, delimiter: null, onLine: null,
            maxLineBytes: null, _onStarted);
        Launch(child);
        ChildProcess.Outcome outcome;
        using (ct.Register(child.Stop))
        {
            outcome = await child.WaitAsync().ConfigureAwait(false);
        }

        ct.ThrowIfCancellationRequested();
        if (outcome.Error(allowedExitCodes ?? [0]) is GitError error)
        {
            throw error;
        }

        return new GitResult(outcome.ExitCode, outcome.Stdout, outcome.StderrText);
    }

    /// <summary>
    /// Runs <c>git &lt;args&gt;</c> in <paramref name="cwd"/> and yields its output line by line as it arrives (git
    /// starts on the first <c>MoveNextAsync</c>). The enumeration finishes when git exits 0 and throws
    /// <see cref="GitError"/> otherwise. Ending the enumeration early kills git's process tree; cancelling
    /// <paramref name="ct"/> (or the enumerator's token) kills it too and throws
    /// <see cref="OperationCanceledException"/>. With <paramref name="maxLineBytes"/>, a stdout line longer than that
    /// is yielded as its first <paramref name="maxLineBytes"/> bytes, marked truncated, and the rest of it is dropped
    /// as it arrives (memory stays bounded). Use <c>delimiter: 0</c> for <c>-z</c> output.
    /// </summary>
    public async IAsyncEnumerable<Line> StreamAsync(
        IReadOnlyList<string> args, string cwd, IReadOnlyDictionary<string, string> env, byte[]? stdin = null,
        TimeSpan? timeout = null, byte delimiter = (byte)'\n', int? maxLineBytes = null,
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        var channel = Channel.CreateUnbounded<Line>(new UnboundedChannelOptions { SingleReader = true });
        var child = new ChildProcess(Executable, args, cwd, env, stdin, timeout, delimiter,
            line => channel.Writer.TryWrite(line), maxLineBytes, _onStarted);
        Launch(child);
        _ = CompleteAsync(child, channel.Writer);
        var finished = false;
        try
        {
            await foreach (var line in channel.Reader.ReadAllAsync(ct).ConfigureAwait(false))
            {
                yield return line;
            }

            finished = true;
        }
        finally
        {
            if (!finished)
            {
                child.Stop();
            }
        }
    }

    /// <summary>
    /// Runs <paramref name="body"/> after every write queued before it has finished, so writes in one repository run
    /// one at a time, in call order. A failing or cancelled body does not block the lane. Never call it from inside a
    /// body of the same runner: the inner call waits for the outer one (deadlock).
    /// </summary>
    public async Task<T> MutateAsync<T>(Func<CancellationToken, Task<T>> body, CancellationToken ct = default)
    {
        await _lane.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            ct.ThrowIfCancellationRequested();
            return await body(ct).ConfigureAwait(false);
        }
        finally
        {
            _lane.Release();
        }
    }

    /// <summary><see cref="MutateAsync{T}"/> for a body without a result.</summary>
    public Task MutateAsync(Func<CancellationToken, Task> body, CancellationToken ct = default) =>
        MutateAsync(async token =>
        {
            await body(token).ConfigureAwait(false);
            return true;
        }, ct);

    /// <summary>Completes <paramref name="writer"/> once the process finished: with its error, or cleanly on exit 0.</summary>
    private static async Task CompleteAsync(ChildProcess child, ChannelWriter<Line> writer)
    {
        var outcome = await child.WaitAsync().ConfigureAwait(false);
        if (outcome.Error([0]) is GitError error)
        {
            writer.TryComplete(error);
        }
        else
        {
            writer.TryComplete();
        }
    }

    private static void Launch(ChildProcess child)
    {
        try
        {
            child.Start();
        }
        catch (Exception error) when (ChildProcess.IsLaunchError(error))
        {
            throw GitError.LaunchFailed(error.Message);
        }
    }
}

/// <summary>
/// One child process with both pipes drained concurrently (so neither can fill up and block it). With an
/// <c>onLine</c>, output is delivered as lines; without it, stdout is collected whole. <see cref="WaitAsync"/>
/// completes once the process has exited and both pipes reached EOF, or 2 s after the exit when a grandchild (an ssh
/// ControlMaster, a credential helper) still holds a pipe open.
/// </summary>
internal sealed class ChildProcess
{
    internal sealed record Outcome(int ExitCode, byte[] Stdout, byte[] StdoutTail, byte[] StderrTail, bool TimedOut)
    {
        public string StderrText => Encoding.UTF8.GetString(StderrTail);

        /// <summary>The error for this outcome, null when the process exited with an allowed code.</summary>
        public GitError? Error(IReadOnlyCollection<int> allowed)
        {
            if (TimedOut)
            {
                return GitError.Timeout();
            }

            return allowed.Contains(ExitCode)
                ? null
                : GitError.Classify(ExitCode, StderrText, Encoding.UTF8.GetString(StdoutTail));
        }
    }

    internal const int TailBytes = 8 * 1024;

    /// <summary>A stderr line longer than this is not useful progress; it is dropped to bound memory.</summary>
    internal const int MaxStderrLineBytes = 64 * 1024;

    internal static readonly TimeSpan EofGracePeriod = TimeSpan.FromSeconds(2);

    private static readonly UTF8Encoding Utf8NoBom = new(encoderShouldEmitUTF8Identifier: false);

    private readonly string _executable;
    private readonly IReadOnlyList<string> _arguments;
    private readonly string? _cwd;
    private readonly IReadOnlyDictionary<string, string> _environment;
    private readonly byte[]? _stdin;
    private readonly TimeSpan? _timeout;
    private readonly byte? _delimiter;
    private readonly Action<GitRunner.Line>? _onLine;
    private readonly int? _maxLineBytes;
    private readonly Action<Process>? _onStarted;

    private readonly Lock _lock = new();
    private readonly MemoryStream _collected = new();
    private readonly MemoryStream _pendingStdout = new();
    private readonly MemoryStream _pendingStderr = new();
    private readonly MemoryStream _stdoutTail = new();
    private readonly MemoryStream _stderrTail = new();

    /// <summary>A stdout line went over <c>maxLineBytes</c>: its start was emitted, the rest is dropped up to its delimiter.</summary>
    private bool _droppingStdoutLine;

    private Process? _process;
    private bool _stopRequested;
    private bool _exited;
    private bool _timedOut;
    private bool _finished;
    private Task<Outcome>? _run;

    /// <summary><paramref name="delimiter"/> and <paramref name="onLine"/> go together: both null collects stdout,
    /// both set streams lines.</summary>
    internal ChildProcess(
        string executable, IReadOnlyList<string> arguments, string? cwd, IReadOnlyDictionary<string, string> environment,
        byte[]? stdin, TimeSpan? timeout, byte? delimiter, Action<GitRunner.Line>? onLine, int? maxLineBytes,
        Action<Process>? onStarted)
    {
        _executable = executable;
        _arguments = arguments;
        _cwd = cwd;
        _environment = environment;
        _stdin = stdin;
        _timeout = timeout;
        _delimiter = delimiter;
        _onLine = onLine;
        _maxLineBytes = maxLineBytes;
        _onStarted = onStarted;
    }

    /// <summary>The exceptions <see cref="Start"/> throws when the process cannot be started.</summary>
    internal static bool IsLaunchError(Exception error) =>
        error is Win32Exception or InvalidOperationException or IOException or ArgumentException
            or PlatformNotSupportedException or UnauthorizedAccessException;

    /// <summary>
    /// Runs a short command to completion with an empty stdin and returns its outcome (stdout collected), or null when
    /// it cannot be started. It is killed once <paramref name="timeout"/> passes or <paramref name="ct"/> is cancelled
    /// (then <see cref="OperationCanceledException"/>).
    /// </summary>
    internal static async Task<Outcome?> CaptureAsync(
        string executable, IReadOnlyList<string> arguments, IReadOnlyDictionary<string, string> environment,
        TimeSpan timeout, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        var child = new ChildProcess(executable, arguments, cwd: null, environment, stdin: null, timeout,
            delimiter: null, onLine: null, maxLineBytes: null, onStarted: null);
        try
        {
            child.Start();
        }
        catch (Exception error) when (IsLaunchError(error))
        {
            return null;
        }

        Outcome outcome;
        using (ct.Register(child.Stop))
        {
            outcome = await child.WaitAsync().ConfigureAwait(false);
        }

        ct.ThrowIfCancellationRequested();
        return outcome;
    }

    /// <summary>Launches the process. A <see cref="Stop"/> that arrived earlier takes effect right after the launch.</summary>
    internal void Start()
    {
        // Never a bare name: the OS would search the current directory or PATH for it.
        if (!Path.IsPathFullyQualified(_executable))
        {
            throw new ArgumentException($"{_executable} is not an absolute path.");
        }

        var info = new ProcessStartInfo(_executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardInputEncoding = Utf8NoBom,
        };
        if (_cwd is not null)
        {
            info.WorkingDirectory = _cwd;
        }

        foreach (var argument in _arguments)
        {
            info.ArgumentList.Add(argument);
        }

        // ProcessStartInfo starts from this process's environment (case-insensitive keys on Windows); only the
        // caller's may reach git.
        info.Environment.Clear();
        foreach (var (key, value) in _environment)
        {
            if (info.Environment.ContainsKey(key))
            {
                throw new ArgumentException($"The environment sets {key} twice (keys differ only in case).");
            }

            info.Environment[key] = value;
        }

        var process = new Process { StartInfo = info };
        var started = Stopwatch.GetTimestamp();
        try
        {
            process.Start();
        }
        catch
        {
            process.Dispose();
            throw;
        }

        if (_onStarted is not null)
        {
            try
            {
                _onStarted(process);
            }
            catch (Exception error)
            {
                Kill(process);
                process.Dispose();
                throw new InvalidOperationException(error.Message, error);
            }
        }

        bool stopNow;
        lock (_lock)
        {
            _process = process;
            stopNow = _stopRequested;
        }

        _run = RunAsync(process, started);
        if (stopNow)
        {
            Kill(process);
        }
    }

    /// <summary>Kills the process tree. No-op once it exited.</summary>
    internal void Stop()
    {
        Process? process;
        lock (_lock)
        {
            if (_exited || _stopRequested)
            {
                return;
            }

            _stopRequested = true;
            process = _process;
        }

        if (process is not null)
        {
            Kill(process);
        }
    }

    internal Task<Outcome> WaitAsync() => _run ?? throw new InvalidOperationException("The process was not started.");

    private async Task<Outcome> RunAsync(Process process, long started)
    {
        // The only WaitForExitAsync on this process: concurrent calls can lose an Exited handler.
        var exited = process.WaitForExitAsync(CancellationToken.None);
        var exitGrace = AfterExitAsync(exited);
        _ = Task.Run(() => WriteStdinAsync(process));
        using var timer = _timeout is TimeSpan timeout ? new CancellationTokenSource(timeout) : null;
        using var timeoutRegistration = timer?.Token.Register(TimeoutFired) ?? default;
        var stdout = PumpAsync(process.StandardOutput.BaseStream, exitGrace, GitRunner.LineSource.Stdout);
        var stderr = PumpAsync(process.StandardError.BaseStream, exitGrace, GitRunner.LineSource.Stderr);
        await exited.ConfigureAwait(false);
        lock (_lock)
        {
            _exited = true;
        }

        await Task.WhenAll(stdout, stderr).ConfigureAwait(false);
        var exitCode = process.ExitCode;
        Outcome outcome;
        lock (_lock)
        {
            _finished = true;
            _process = null;
            outcome = new Outcome(exitCode, _collected.ToArray(), Tail(_stdoutTail), Tail(_stderrTail), _timedOut);
        }

        process.Dispose();
        if (GitRunner.ProcessObserver is { } observer)
        {
            Observe(observer, exitCode, Stopwatch.GetElapsedTime(started).TotalMilliseconds);
        }

        return outcome;
    }

    /// <summary>Completes <see cref="EofGracePeriod"/> after <paramref name="exited"/>.</summary>
    private static async Task AfterExitAsync(Task exited)
    {
        await exited.ConfigureAwait(false);
        await Task.Delay(EofGracePeriod).ConfigureAwait(false);
    }

    private void TimeoutFired()
    {
        lock (_lock)
        {
            if (_exited)
            {
                return;
            }

            _timedOut = true;
        }

        Stop();
    }

    /// <summary>
    /// Writes stdin off the reading path (git may read it only after writing output), then closes it; with no data it
    /// is closed at once, so git reads EOF as from the null device instead of the app's own stdin.
    /// </summary>
    private async Task WriteStdinAsync(Process process)
    {
        try
        {
            if (_stdin is { Length: > 0 } data)
            {
                await process.StandardInput.BaseStream.WriteAsync(data).ConfigureAwait(false);
            }
        }
        catch (Exception error) when (error is IOException or ObjectDisposedException or InvalidOperationException)
        {
            // git exited before reading everything.
        }
        finally
        {
            try
            {
                process.StandardInput.Close();
            }
            catch (Exception error) when (error is IOException or ObjectDisposedException or InvalidOperationException)
            {
                // Already gone.
            }
        }
    }

    /// <summary>
    /// Reads <paramref name="stream"/> as bytes until EOF, or until <paramref name="exitGrace"/> completes (a
    /// grandchild that inherited the pipe keeps it open; the pending read is then abandoned), then flushes the
    /// unterminated last line of <paramref name="source"/>.
    /// </summary>
    private async Task PumpAsync(Stream stream, Task exitGrace, GitRunner.LineSource source)
    {
        var buffer = new byte[64 * 1024];
        try
        {
            while (true)
            {
                var read = stream.ReadAsync(buffer).AsTask();
                if (await Task.WhenAny(read, exitGrace).ConfigureAwait(false) != read)
                {
                    _ = read.ContinueWith(task => task.Exception, TaskScheduler.Default);
                    break;
                }

                var count = await read.ConfigureAwait(false);
                if (count == 0)
                {
                    break;
                }

                lock (_lock)
                {
                    Read(buffer.AsSpan(0, count), source);
                }
            }
        }
        catch (Exception error) when (error is IOException or ObjectDisposedException)
        {
            // A broken pipe ends the output like EOF.
        }

        lock (_lock)
        {
            Flush(source);
        }
    }

    /// <summary>Takes one chunk of output. Lock held, so lines keep their order and none is emitted after the outcome.</summary>
    private void Read(ReadOnlySpan<byte> data, GitRunner.LineSource source)
    {
        if (_finished)
        {
            return;
        }

        if (source == GitRunner.LineSource.Stderr)
        {
            AppendTail(data, _stderrTail);
            if (_onLine is null)
            {
                return;
            }

            EmitLines(data, _pendingStderr, source, "\n\r"u8);
            if (_pendingStderr.Length > MaxStderrLineBytes)
            {
                _pendingStderr.SetLength(0);
            }

            return;
        }

        AppendTail(data, _stdoutTail);
        if (_delimiter is not byte delimiter)
        {
            _collected.Write(data);
            return;
        }

        if (_droppingStdoutLine)
        {
            var end = data.IndexOf(delimiter);
            if (end < 0)
            {
                return;
            }

            _droppingStdoutLine = false;
            data = data[(end + 1)..];
        }

        EmitLines(data, _pendingStdout, source, [delimiter]);
        if (_maxLineBytes is int maxLineBytes && _pendingStdout.Length > maxLineBytes)
        {
            Emit(Pending(_pendingStdout), source); // Cut to maxLineBytes there.
            _pendingStdout.SetLength(0);
            _droppingStdoutLine = true;
        }
    }

    /// <summary>
    /// Emits every complete line of <paramref name="pending"/> followed by <paramref name="data"/> (a line ends at any
    /// byte of <paramref name="ends"/>) and keeps the unterminated rest in <paramref name="pending"/>.
    /// </summary>
    private void EmitLines(
        ReadOnlySpan<byte> data, MemoryStream pending, GitRunner.LineSource source, ReadOnlySpan<byte> ends)
    {
        while (true)
        {
            var end = data.IndexOfAny(ends);
            if (end < 0)
            {
                break;
            }

            if (pending.Length == 0)
            {
                Emit(data[..end], source);
            }
            else
            {
                pending.Write(data[..end]);
                Emit(Pending(pending), source);
                pending.SetLength(0);
            }

            data = data[(end + 1)..];
        }

        pending.Write(data);
    }

    /// <summary>A stdout line longer than <c>maxLineBytes</c> (complete or not) is emitted as its start, marked truncated.</summary>
    private void Emit(ReadOnlySpan<byte> line, GitRunner.LineSource source)
    {
        if (_onLine is null || (source == GitRunner.LineSource.Stderr && line.IsEmpty))
        {
            return;
        }

        if (source == GitRunner.LineSource.Stdout && _maxLineBytes is int maxLineBytes && line.Length > maxLineBytes)
        {
            _onLine(new GitRunner.Line(source, Encoding.UTF8.GetString(line[..maxLineBytes]), Truncated: true));
            return;
        }

        _onLine(new GitRunner.Line(source, Encoding.UTF8.GetString(line)));
    }

    /// <summary>Emits the unterminated last line of <paramref name="source"/>, if any. Lock held.</summary>
    private void Flush(GitRunner.LineSource source)
    {
        if (_onLine is null || _finished)
        {
            return;
        }

        var pending = source == GitRunner.LineSource.Stdout ? _pendingStdout : _pendingStderr;
        if (pending.Length > 0)
        {
            Emit(Pending(pending), source);
        }

        pending.SetLength(0);
    }

    private static ReadOnlySpan<byte> Pending(MemoryStream pending) =>
        pending.GetBuffer().AsSpan(0, (int)pending.Length);

    /// <summary>Appends to <paramref name="tail"/>, keeping at least its last <see cref="TailBytes"/>.</summary>
    private static void AppendTail(ReadOnlySpan<byte> data, MemoryStream tail)
    {
        if (data.Length >= TailBytes)
        {
            tail.SetLength(0);
            tail.Write(data[^TailBytes..]);
            return;
        }

        tail.Write(data);
        if (tail.Length > 2 * TailBytes)
        {
            var kept = tail.GetBuffer().AsSpan((int)tail.Length - TailBytes, TailBytes).ToArray();
            tail.SetLength(0);
            tail.Write(kept);
        }
    }

    /// <summary>The last <see cref="TailBytes"/> of <paramref name="tail"/>.</summary>
    private static byte[] Tail(MemoryStream tail)
    {
        var length = (int)Math.Min(tail.Length, TailBytes);
        return tail.GetBuffer().AsSpan((int)tail.Length - length, length).ToArray();
    }

    /// <summary>Reports this finished process to <paramref name="observer"/> (only its verb: other arguments can hold
    /// remote URLs).</summary>
    private void Observe(Action<string, double, string, int, int?> observer, int exitCode, double ms)
    {
        var index = 0;
        while (index < _arguments.Count
               && (_arguments[index].StartsWith("--", StringComparison.Ordinal) || _arguments[index] == "-c"
                   || _arguments[index] == "-C"))
        {
            index += _arguments[index].StartsWith("--", StringComparison.Ordinal) ? 1 : 2;
        }

        var verb = index < _arguments.Count ? _arguments[index] : _arguments.Count > 0 ? _arguments[0] : "";
        var folder = _cwd is null ? "" : Path.GetFileName(Path.TrimEndingDirectorySeparator(_cwd));
        observer(verb, ms, folder.Length > 0 ? folder : "-", exitCode, null);
    }

    private static void Kill(Process process)
    {
        try
        {
            process.Kill(entireProcessTree: true);
        }
        catch (Exception error) when (error is InvalidOperationException or Win32Exception or NotSupportedException
                                          or AggregateException or ObjectDisposedException)
        {
            // Already exited.
        }
    }
}
