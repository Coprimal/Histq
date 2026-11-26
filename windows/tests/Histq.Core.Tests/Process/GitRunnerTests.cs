// Key feature tests for the process layer: a failing git command surfaces its exit code and stderr tail, allowed exit
// codes and stdin reach the caller, cancelling a stream really stops the child process and its children, a stream cuts
// an over-long line (yielded before EOF) and resumes at the next one, NUL-split output keeps non-ASCII text, a timeout
// kills git, writes run one at a time in call order, and GitExecutable rejects a git older than 2.36 while accepting
// 2.36 itself. Fake gits are bash scripts (`bash -c`), so the same tests run on the Mac and on Windows.
using System.Collections.Concurrent;
using System.Diagnostics;

namespace Histq.Core.Tests;

public sealed class GitRunnerTests
{
    private static CancellationToken Token => TestContext.Current.CancellationToken;

    // A failing command throws GitError with its exit code and stderr tail.
    [Fact]
    public async Task FailingCommandReportsExitCodeAndStderrTail()
    {
        var folder = Fixtures.MakeTempDirectory();
        try
        {
            var work = Path.Combine(folder, "not-a-repo");
            Directory.CreateDirectory(work);
            var env = Fixtures.HermeticEnvironment(folder);
            // Never discover a repo above the temp folder, whatever the machine's temp path is inside.
            env["GIT_CEILING_DIRECTORIES"] = folder;

            var runner = new GitRunner(await Fixtures.GitAsync());
            var error = await Assert.ThrowsAsync<GitError>(() =>
                runner.RunAsync(["rev-parse", "--git-dir"], work, env, timeout: TimeSpan.FromSeconds(30), ct: Token));
            Assert.Equal(128, error.ExitCode);
            Assert.Contains("not a git repository", error.StderrTail, StringComparison.Ordinal);
            Assert.Equal(GitError.Other(128, error.StderrTail), error);
        }
        finally
        {
            Fixtures.RemoveTempDirectory(folder);
        }
    }

    // An allowed non-zero exit code is a result, not an error.
    [Fact]
    public async Task AllowedExitCodeIsAResult()
    {
        var folder = Fixtures.MakeTempDirectory();
        try
        {
            var env = Fixtures.HermeticEnvironment(folder);
            var runner = new GitRunner(await Fixtures.GitAsync());
            string[] args = ["config", "--get", "histq.no-such-key"];

            var result = await runner.RunAsync(args, folder, env, allowedExitCodes: [0, 1], ct: Token);
            Assert.Equal(1, result.ExitCode);
            Assert.Empty(result.Stdout);

            var error = await Assert.ThrowsAsync<GitError>(() => runner.RunAsync(args, folder, env, ct: Token));
            Assert.Equal(1, error.ExitCode);
        }
        finally
        {
            Fixtures.RemoveTempDirectory(folder);
        }
    }

    // Stdin reaches git (in a copy of the fixture repos).
    [Fact]
    public async Task StdinReachesGit()
    {
        using var copy = await Fixtures.CopyAsync();
        var repo = copy.Repo("graph");
        var content = "stdin from Histq\n"u8.ToArray();

        var hash = await copy.GitAsync(["hash-object", "-w", "--stdin"], repo, content, Token);
        Assert.Matches("^[0-9a-f]{40}$", hash);
        Assert.Equal("stdin from Histq", await copy.GitAsync(["cat-file", "-p", hash], repo, ct: Token));
    }

    // Cancelling the stream's consumer kills the child process and its children (the whole tree).
    [Fact]
    public async Task CancellingStreamTerminatesChild()
    {
        var folder = Fixtures.MakeTempDirectory();
        try
        {
            // The child prints forever; its background subshell (a grandchild) appends to a heartbeat file.
            var heartbeat = Path.Combine(folder, "heartbeat");
            const string script = """
                ( while :; do echo beat >> "$1"; sleep 0.1; done ) &
                while :; do echo tick; done
                """;
            var env = Fixtures.HermeticEnvironment(folder);
            var childId = new TaskCompletionSource<int>(TaskCreationOptions.RunContinuationsAsynchronously);
            var runner = new GitRunner(await Fixtures.BashAsync(), process => childId.TrySetResult(process.Id));
            using var cancel = CancellationTokenSource.CreateLinkedTokenSource(Token);
            var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var consumer = Task.Run(async () =>
            {
                await foreach (var _ in runner.StreamAsync(
                                   ["-c", script, "sh", Fixtures.ShellPath(heartbeat)], folder, env, ct: cancel.Token))
                {
                    ready.TrySetResult();
                }
            }, Token);

            await ready.Task.WaitAsync(TimeSpan.FromSeconds(30), Token);
            var child = await childId.Task.WaitAsync(TimeSpan.FromSeconds(5), Token);
            Assert.True(IsRunning(child), "the child runs before the cancel");
            Assert.True(await Poll(TimeSpan.FromSeconds(5), () => Task.FromResult(Length(heartbeat) > 0)),
                "the grandchild never wrote its heartbeat");

            await cancel.CancelAsync();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => consumer);
            Assert.True(await Poll(TimeSpan.FromSeconds(5), () => Task.FromResult(!IsRunning(child))),
                "the child process is still running 5 s after the cancel");
            Assert.True(await Poll(TimeSpan.FromSeconds(5), async () =>
            {
                var before = Length(heartbeat);
                await Task.Delay(TimeSpan.FromMilliseconds(500), Token);
                return Length(heartbeat) == before;
            }), "the grandchild still writes its heartbeat 5 s after the cancel");
        }
        finally
        {
            Fixtures.RemoveTempDirectory(folder);
        }
    }

    // A stream cuts a stdout line at maxLineBytes, drops its rest and resumes at the next line.
    [Fact]
    public async Task StreamCutsLongLineAndResumes()
    {
        var folder = Fixtures.MakeTempDirectory();
        try
        {
            const string script = """
                head -c 1000000 /dev/zero | tr '\0' q
                printf '\nshort\n'
                """;
            var env = Fixtures.HermeticEnvironment(folder);

            var lines = new List<GitRunner.Line>();
            await foreach (var line in new GitRunner(await Fixtures.BashAsync()).StreamAsync(
                               ["-c", script], folder, env, timeout: TimeSpan.FromSeconds(30), maxLineBytes: 4_096,
                               ct: Token))
            {
                if (line.Source == GitRunner.LineSource.Stdout)
                {
                    lines.Add(line);
                }
            }

            Assert.Equal(2, lines.Count);
            Assert.True(lines[0].Truncated);
            Assert.Equal(new string('q', 4_096), lines[0].Text);
            Assert.Equal("short", lines[1].Text);
            Assert.False(lines[1].Truncated);
        }
        finally
        {
            Fixtures.RemoveTempDirectory(folder);
        }
    }

    // A cut line is yielded while git is still writing it, before any delimiter or EOF.
    [Fact]
    public async Task StreamYieldsCutLineBeforeEOF()
    {
        var folder = Fixtures.MakeTempDirectory();
        try
        {
            // Shell builtins only: one endless line.
            const string script = "while :; do printf 'qqqqqqqqqqqqqqqq'; done";
            var env = Fixtures.HermeticEnvironment(folder);

            GitRunner.Line? first = null;
            await foreach (var line in new GitRunner(await Fixtures.BashAsync()).StreamAsync(
                               ["-c", script], folder, env, timeout: TimeSpan.FromSeconds(30), maxLineBytes: 4_096,
                               ct: Token))
            {
                first = line;
                break;
            }

            Assert.NotNull(first);
            Assert.Equal(GitRunner.LineSource.Stdout, first.Value.Source);
            Assert.True(first.Value.Truncated);
            Assert.Equal(4_096, first.Value.Text.Length);
        }
        finally
        {
            Fixtures.RemoveTempDirectory(folder);
        }
    }

    // A NUL-delimited stream (-z output) splits on NUL only and decodes each entry as UTF-8.
    [Fact]
    public async Task StreamSplitsOnNulAndKeepsNonAsciiText()
    {
        var folder = Fixtures.MakeTempDirectory();
        try
        {
            // ASCII-only script: "a\nb", "café", "日本/ü.txt" as UTF-8 octal escapes.
            const string script = @"printf 'a\nb\0caf\303\251\0\346\227\245\346\234\254/\303\274.txt\0'";
            var env = Fixtures.HermeticEnvironment(folder);

            var lines = new List<string>();
            await foreach (var line in new GitRunner(await Fixtures.BashAsync()).StreamAsync(
                               ["-c", script], folder, env, timeout: TimeSpan.FromSeconds(30), delimiter: 0, ct: Token))
            {
                lines.Add(line.Text);
            }

            Assert.Equal(["a\nb", "café", "日本/ü.txt"], lines);
        }
        finally
        {
            Fixtures.RemoveTempDirectory(folder);
        }
    }

    // A command that runs past its timeout is killed and fails with GitError.Timeout.
    [Fact]
    public async Task TimeoutKillsTheCommand()
    {
        var folder = Fixtures.MakeTempDirectory();
        try
        {
            var env = Fixtures.HermeticEnvironment(folder);
            var runner = new GitRunner(await Fixtures.BashAsync());
            var clock = Stopwatch.StartNew();

            var error = await Assert.ThrowsAsync<GitError>(() =>
                runner.RunAsync(["-c", "sleep 30"], folder, env, timeout: TimeSpan.FromMilliseconds(300), ct: Token));
            Assert.Equal(GitErrorKind.Timeout, error.Kind);
            Assert.True(clock.Elapsed < TimeSpan.FromSeconds(10), $"took {clock.Elapsed}");
        }
        finally
        {
            Fixtures.RemoveTempDirectory(folder);
        }
    }

    // Writes run one at a time in call order, and a failing one does not block the lane.
    [Fact]
    public async Task MutateRunsWritesInCallOrder()
    {
        var runner = new GitRunner(Fixtures.NullDevice);
        var order = new ConcurrentQueue<string>();
        var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        var first = runner.MutateAsync(async _ =>
        {
            order.Enqueue("first start");
            await gate.Task;
            order.Enqueue("first end");
            throw new InvalidOperationException("first failed");
        }, Token);
        var second = runner.MutateAsync(async _ =>
        {
            order.Enqueue("second");
            await Task.Yield();
            return 2;
        }, Token);
        var third = runner.MutateAsync(_ =>
        {
            order.Enqueue("third");
            return Task.CompletedTask;
        }, Token);

        await Task.Delay(TimeSpan.FromMilliseconds(100), Token);
        Assert.Equal(["first start"], order);
        gate.SetResult();
        await Assert.ThrowsAsync<InvalidOperationException>(() => first);
        Assert.Equal(2, await second);
        await third;
        Assert.Equal(["first start", "first end", "second", "third"], order);
    }

    // GitExecutable rejects git 2.35.1 as too old and accepts git 2.36.0.
    [Fact]
    public async Task ExecutableEnforcesMinimumVersion()
    {
        Assert.SkipWhen(OperatingSystem.IsWindows(), "Fake gits are shell scripts, which Windows cannot run as git.exe.");
        var folder = Fixtures.MakeTempDirectory();
        try
        {
            var old = Path.Combine(folder, "old", "git");
            var current = Path.Combine(folder, "current", "git");
            Fixtures.WriteScript("echo 'git version 2.35.1'", old);
            Fixtures.WriteScript("echo 'git version 2.36.0'", current);

            var error = await Assert.ThrowsAsync<GitExecutableError>(() =>
                GitExecutable.ResolveAsync(overridePath: old, ct: Token));
            Assert.Equal(GitExecutableError.TooOld(new GitVersion(2, 35, 1)), error);
            var accepted = await GitExecutable.ResolveAsync(overridePath: current, ct: Token);
            Assert.Equal(new GitVersion(2, 36, 0), accepted.Version);
            Assert.Equal(current, accepted.ExecutablePath);
        }
        finally
        {
            Fixtures.RemoveTempDirectory(folder);
        }
    }

    // Helpers.

    /// <summary>True while the process <paramref name="id"/> exists and has not exited.</summary>
    private static bool IsRunning(int id)
    {
        try
        {
            using var process = System.Diagnostics.Process.GetProcessById(id);
            return !process.HasExited;
        }
        catch (Exception error) when (error is ArgumentException or InvalidOperationException)
        {
            return false;
        }
    }

    private static long Length(string path) => File.Exists(path) ? new FileInfo(path).Length : 0;

    /// <summary>Checks <paramref name="condition"/> every 50 ms until it holds (true) or <paramref name="limit"/> passes (false).</summary>
    private static async Task<bool> Poll(TimeSpan limit, Func<Task<bool>> condition)
    {
        var clock = Stopwatch.StartNew();
        while (clock.Elapsed < limit)
        {
            if (await condition())
            {
                return true;
            }

            await Task.Delay(TimeSpan.FromMilliseconds(50), Token);
        }

        return await condition();
    }
}
