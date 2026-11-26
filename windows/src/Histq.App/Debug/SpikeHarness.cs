#if HISTQ_QA
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using Histq.App.Graph;
using Histq.Core;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;

namespace Histq.App;

public partial class App
{
    /// <summary>The main window once <see cref="OnLaunched"/> has made it (QA builds, for <see cref="SpikeHarness"/>).</summary>
    internal MainWindow? QaMainWindow => _window;
}

/// <summary>
/// The phase 5 spike harness (QA builds only). Launch flags: <c>-HistqStateDir &lt;dir&gt;</c>,
/// <c>-HistqWindowSize W,H</c> (the client size in physical pixels), <c>-HistqSpikeLog &lt;dump&gt;</c> (a
/// NUL-terminated log in <see cref="LogReader.Arguments"/>' format, made by windows/scripts/qa-data.sh dump) and
/// <c>-HistqScrollProbe &lt;seconds&gt;</c> (default 10).
/// <para>
/// Without <c>-HistqSpikeLog</c> it only sizes the window, which stays open for the interactive title-bar checks. With
/// it, the dump is parsed and laid out off the UI thread in pages, each page handed to the graph on the UI thread; then
/// the scroll, precision and click probes run, <c>&lt;stateDir&gt;\Probes\spike.json</c> is written and the process
/// exits 0, or non-zero with the error in spike.json.
/// </para>
/// </summary>
internal sealed class SpikeHarness
{
    private const string WindowSizeFlag = "-HistqWindowSize";
    private const string SpikeLogFlag = "-HistqSpikeLog";
    private const string ScrollProbeFlag = "-HistqScrollProbe";

    private const int FirstPageSize = LogReader.DefaultPageSize;
    private const int PageSize = 20_000;

    /// <summary>The programmatic scroll speed of the scroll probe.</summary>
    private const double RowsPerSecond = 2000;

    /// <summary>Wheel notches the scroll probe sends, spread over its duration; one notch scrolls 3 rows.</summary>
    private const int WheelSteps = 200;

    private const double WheelRows = 3;

    private static readonly TimeSpan WaitLimit = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan DrawWait = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan Watchdog = TimeSpan.FromMinutes(25);

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    private readonly LaunchFlags _flags;
    private readonly string _probePath;
    /// <summary>The process's age when the harness was made; <see cref="_clock"/> runs from then.</summary>
    private readonly TimeSpan _startAge;
    private readonly Stopwatch _clock;
    private readonly SpikeResult _result = new();
    private readonly Lock _writeLock = new();

    private GraphCanvas? _canvas;
    private GraphDrawInfo? _lastDraw;

    private SpikeHarness(IReadOnlyList<string> arguments)
    {
        _flags = new LaunchFlags(arguments);
        StatePaths paths = StatePaths.Resolve(arguments, Environment.GetEnvironmentVariable);
        _probePath = Path.Combine(paths.Root, "Probes", "spike.json");
        // One wall-clock reading: a clock step during the run (a VM syncing its time) cannot skew the timings.
        using var process = Process.GetCurrentProcess();
        _startAge = DateTime.Now - process.StartTime;
        _clock = Stopwatch.StartNew();
    }

    /// <summary>
    /// Starts the harness; call on the UI thread right after the <see cref="App"/> is made. The dump starts loading at
    /// once; everything else waits for the main window.
    /// </summary>
    public static void Start(IReadOnlyList<string> arguments)
    {
        var harness = new SpikeHarness(arguments);
        string? log = harness._flags.String(SpikeLogFlag);
        ChannelReader<Page>? pages = null;
        if (!string.IsNullOrEmpty(log))
        {
            pages = Load(log);
            Application.Current.UnhandledException += (_, e) => harness.Fail(e.Exception.ToString(), 1);
        }

        _ = harness.RunAsync(pages);
    }

    /// <summary>
    /// Never throws. With a dump, any failure is written to spike.json and exits the process; without one, a failure
    /// (the window size not applied) is ignored and the app stays up.
    /// </summary>
    private async Task RunAsync(ChannelReader<Page>? pages)
    {
        try
        {
            if (pages is not null)
            {
                _ = Task.Delay(Watchdog).ContinueWith(
                    _ => Fail($"watchdog: the spike did not finish in {Watchdog.TotalMinutes} minutes", 3),
                    TaskScheduler.Default);
            }

            MainWindow window = await WaitForAsync(() => (Application.Current as App)?.QaMainWindow, "the main window");
            if (_flags.Size(WindowSizeFlag) is var (width, height))
                window.AppWindow.ResizeClient(new SizeInt32(width, height));
            if (pages is null)
                return;

            _canvas = window.GraphCanvas;
            _canvas.DrawCompleted += OnDrawCompleted;
            await LoadRowsAsync(pages);
            await WaitForAsync(
                () => _result.FirstRowsMs is not null && _canvas.ViewportHeight > 0 ? _canvas : null,
                "the first rows drawn");
            SizeInt32 client = window.AppWindow.ClientSize;
            _result.ClientSize = $"{client.Width},{client.Height}";
            _result.RowHeight = _canvas.RowHeight;
            _result.ViewportHeight = _canvas.ViewportHeight;

            await ScrollProbeAsync(_flags.Double(ScrollProbeFlag) ?? 10);
            await PrecisionProbeAsync();
            await ClickProbeAsync();
            _result.Backdrop = window.SystemBackdrop switch
            {
                MicaBackdrop => "mica",
                DesktopAcrylicBackdrop => "acrylic",
                _ => "none",
            };
            _result.MicaSupported = MicaController.IsSupported();

            Write();
            Environment.Exit(0);
        }
        catch (Exception e) when (pages is not null)
        {
            Fail(e.ToString(), 1);
        }
        catch (Exception e)
        {
            Debug.WriteLine($"SpikeHarness: {e}");
        }
    }

    /// <summary>Writes spike.json with <paramref name="error"/> and exits with <paramref name="code"/>.</summary>
    private void Fail(string error, int code)
    {
        _result.Error = error;
        try
        {
            Write();
        }
        finally
        {
            Environment.Exit(code);
        }
    }

    private void Write()
    {
        lock (_writeLock)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_probePath)!);
            File.WriteAllText(_probePath, JsonSerializer.Serialize(_result, JsonOptions));
        }
    }

    private double SinceLaunchMs() => (_startAge + _clock.Elapsed).TotalMilliseconds;

    private void OnDrawCompleted(object? sender, GraphDrawInfo info)
    {
        _lastDraw = info;
        if (_result.FirstRowsMs is null && info.FirstRow >= 0)
            _result.FirstRowsMs = SinceLaunchMs();
    }

    // ---- Load ----

    /// <summary>A laid-out page: <see cref="Rows"/>[i] is the row of <see cref="Commits"/>[i].</summary>
    private sealed record Page(GraphRow[] Rows, List<Commit> Commits);

    /// <summary>Parses the dump on one thread and lays it out on another; the pages come out in order.</summary>
    private static ChannelReader<Page> Load(string path)
    {
        var parsed = Channel.CreateUnbounded<List<Commit>>(new UnboundedChannelOptions { SingleReader = true, SingleWriter = true });
        var laidOut = Channel.CreateUnbounded<Page>(new UnboundedChannelOptions { SingleReader = true, SingleWriter = true });
        _ = Task.Run(() => Parse(path, parsed.Writer));
        _ = Task.Run(() => LayOutAsync(parsed.Reader, laidOut.Writer));
        return laidOut.Reader;
    }

    /// <summary>Reads NUL-terminated records (a last one without NUL too) and parses them in pages.</summary>
    private static void Parse(string path, ChannelWriter<List<Commit>> output)
    {
        try
        {
            using var reader = new StreamReader(
                path,
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false),
                detectEncodingFromByteOrderMarks: false,
                new FileStreamOptions { BufferSize = 1 << 16, Options = FileOptions.SequentialScan });
            var names = new Dictionary<string, string>(StringComparer.Ordinal);
            // A small first page, so the first rows show early.
            int pageSize = FirstPageSize;
            var page = new List<Commit>(pageSize);
            var buffer = new char[1 << 20];
            int end = 0;

            void Add(ReadOnlySpan<char> record)
            {
                if (LogParser.Parse(record, names) is not { } commit)
                    return;
                page.Add(commit);
                if (page.Count >= pageSize)
                {
                    output.TryWrite(page);
                    pageSize = PageSize;
                    page = new List<Commit>(pageSize);
                }
            }

            while (true)
            {
                // A record longer than the buffer (a huge message) grows it.
                if (end == buffer.Length)
                    Array.Resize(ref buffer, buffer.Length * 2);
                int read = reader.Read(buffer, end, buffer.Length - end);
                if (read == 0)
                {
                    Add(buffer.AsSpan(0, end));
                    break;
                }

                int start = 0;
                int scan = end;
                end += read;
                int nul;
                while ((nul = buffer.AsSpan(scan, end - scan).IndexOf('\0')) >= 0)
                {
                    nul += scan;
                    Add(buffer.AsSpan(start, nul - start));
                    start = scan = nul + 1;
                }

                Array.Copy(buffer, start, buffer, 0, end - start);
                end -= start;
            }

            if (page.Count > 0)
                output.TryWrite(page);
            output.TryComplete();
        }
        catch (Exception e)
        {
            output.TryComplete(e);
        }
    }

    private static async Task LayOutAsync(ChannelReader<List<Commit>> input, ChannelWriter<Page> output)
    {
        try
        {
            var layout = new GraphLayout();
            await foreach (List<Commit> commits in input.ReadAllAsync().ConfigureAwait(false))
                output.TryWrite(new Page(layout.Append(commits), commits));
            output.TryComplete();
        }
        catch (Exception e)
        {
            output.TryComplete(e);
        }
    }

    /// <summary>Hands every page to the graph on the UI thread as it comes (the canvas lists change only here).</summary>
    private async Task LoadRowsAsync(ChannelReader<Page> pages)
    {
        var rows = new List<GraphRow>();
        var commits = new List<Commit>();
        await foreach (Page page in pages.ReadAllAsync())
        {
            rows.AddRange(page.Rows);
            commits.AddRange(page.Commits);
            _canvas!.SetRows(rows, commits);
        }

        _result.FullLoadMs = SinceLaunchMs();
        _result.ParsedCommits = commits.Count;
    }

    // ---- Probes ----

    /// <summary>
    /// For <paramref name="seconds"/>: every frame scrolls at <see cref="RowsPerSecond"/>, and <see cref="WheelSteps"/>
    /// wheel-notch steps are spread over the run; the direction turns at either end. Records the frame intervals
    /// (RenderingTime deltas) and the canvas's draw times.
    /// </summary>
    private async Task ScrollProbeAsync(double seconds)
    {
        GraphCanvas canvas = _canvas!;
        double rh = canvas.RowHeight;
        var intervals = new List<double>();
        var draws = new List<double>();
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        TimeSpan? first = null;
        TimeSpan? previous = null;
        int wheelSent = 0;
        double direction = 1;

        void OnDraw(object? sender, GraphDrawInfo info) => draws.Add(info.DrawMs);

        void OnRendering(object? sender, object e)
        {
            try
            {
                TimeSpan time = ((RenderingEventArgs)e).RenderingTime;
                // Rendering can be raised more than once per frame, with the same time.
                if (previous == time)
                    return;
                double elapsed = first is { } start ? (time - start).TotalSeconds : 0;
                if (previous is { } last)
                    intervals.Add((time - last).TotalMilliseconds);
                double dt = previous is { } before ? (time - before).TotalSeconds : 0;
                first ??= time;
                previous = time;

                if (canvas.LastVisibleRow >= canvas.RowCount - 1 && direction > 0)
                    direction = -1;
                else if (canvas.FirstRow == 0 && canvas.PixelInRow == 0 && direction < 0)
                    direction = 1;

                canvas.ScrollByPixels(direction * RowsPerSecond * dt * rh);
                int due = elapsed >= seconds ? WheelSteps : (int)Math.Min(WheelSteps, Math.Floor(WheelSteps * elapsed / seconds));
                for (; wheelSent < due; wheelSent++)
                    canvas.ScrollByPixels(direction * WheelRows * rh);

                if (elapsed >= seconds)
                    done.TrySetResult();
            }
            catch (Exception exception)
            {
                done.TrySetException(exception);
            }
        }

        canvas.DrawCompleted += OnDraw;
        CompositionTarget.Rendering += OnRendering;
        try
        {
            await WithTimeout(done.Task, TimeSpan.FromSeconds(seconds) + WaitLimit, "the scroll probe");
        }
        finally
        {
            CompositionTarget.Rendering -= OnRendering;
            canvas.DrawCompleted -= OnDraw;
        }

        intervals.Sort();
        draws.Sort();
        _result.ScrollSeconds = seconds;
        _result.FrameCount = intervals.Count + 1;
        _result.DrawCount = draws.Count;
        _result.WheelStepsSent = wheelSent;
        _result.FrameIntervalMedianMs = Percentile(intervals, 0.5);
        _result.FrameIntervalP95Ms = Percentile(intervals, 0.95);
        _result.FrameIntervalMaxMs = intervals.Count > 0 ? intervals[^1] : null;
        _result.DrawMsP95 = Percentile(draws, 0.95);
    }

    /// <summary>
    /// End: the last row drawn, fully, and hit-tested at its center. Then 5 rows spread over the log, each scrolled to
    /// the top (or as near as the end allows): its top edge against the exact one (decimal), and a hit test at its center.
    /// </summary>
    private async Task PrecisionProbeAsync()
    {
        GraphCanvas canvas = _canvas!;
        double rh = canvas.RowHeight;
        long count = canvas.RowCount;

        Task<GraphDrawInfo?> next = NextDrawAsync();
        canvas.ScrollToEnd();
        GraphDrawInfo end = await next ?? _lastDraw ?? throw new InvalidOperationException("no frame was drawn");
        _result.LastRowIndex = end.LastRow;
        _result.LastRowFullyDrawn = end.LastRowFullyDrawn;
        _result.LastRowHitTest = canvas.HitTest(canvas.TopOfRow(end.LastRow) + rh / 2);

        var rows = new long[5];
        var matches = new bool[5];
        double error = 0;
        decimal maxOffset = Math.Max(0, count * (decimal)rh - (decimal)canvas.ViewportHeight);
        for (int k = 0; k < rows.Length; k++)
        {
            long row = (count - 1) * k / (rows.Length - 1);
            next = NextDrawAsync();
            canvas.ScrollToRow(row);
            await next;

            double top = canvas.TopOfRow(row);
            decimal exact = row * (decimal)rh - Math.Min(row * (decimal)rh, maxOffset);
            error = Math.Max(error, Math.Abs(top - (double)exact));
            rows[k] = row;
            matches[k] = canvas.HitTest(top + rh / 2) == row;
        }

        _result.HitTestRows = rows;
        _result.HitTestMatches = matches;
        _result.RowTopErrorPx = error;
    }

    /// <summary>
    /// Selects a visible row the way a press does (<see cref="GraphCanvas.Select"/>, from a plain UI-thread callback,
    /// not from a frame callback). Frames = 1 + the frames rendered before the draw that shows the highlight, so 1
    /// means it showed in the first frame after the press.
    /// </summary>
    private async Task ClickProbeAsync()
    {
        GraphCanvas canvas = _canvas!;
        await Task.Delay(100);
        long row = Math.Min(canvas.FirstVisibleRow + 1, canvas.LastVisibleRow);
        if (row == canvas.SelectedRow)
            row = canvas.FirstVisibleRow;
        if (row < 0 || row == canvas.SelectedRow)
            throw new InvalidOperationException("no visible row to select");

        int rendered = 0;
        var shown = new TaskCompletionSource<int>(TaskCreationOptions.RunContinuationsAsynchronously);
        void OnRendered(object? sender, RenderedEventArgs e) => rendered++;
        void OnDraw(object? sender, GraphDrawInfo info)
        {
            if (info.SelectedRow == row)
                shown.TrySetResult(rendered);
        }

        CompositionTarget.Rendered += OnRendered;
        canvas.DrawCompleted += OnDraw;
        try
        {
            canvas.Select(row);
            _result.ClickToHighlightFrames = 1 + await WithTimeout(shown.Task, DrawWait, "the selected row's draw");
            _result.ClickRow = row;
        }
        finally
        {
            canvas.DrawCompleted -= OnDraw;
            CompositionTarget.Rendered -= OnRendered;
        }
    }

    // ---- Helpers ----

    /// <summary>The next draw's info, or null when nothing is drawn within <see cref="DrawWait"/> (no change to draw).</summary>
    private async Task<GraphDrawInfo?> NextDrawAsync()
    {
        GraphCanvas canvas = _canvas!;
        var drawn = new TaskCompletionSource<GraphDrawInfo>(TaskCreationOptions.RunContinuationsAsynchronously);
        void OnDraw(object? sender, GraphDrawInfo info) => drawn.TrySetResult(info);
        canvas.DrawCompleted += OnDraw;
        try
        {
            return await Task.WhenAny(drawn.Task, Task.Delay(DrawWait)) == drawn.Task ? await drawn.Task : null;
        }
        finally
        {
            canvas.DrawCompleted -= OnDraw;
        }
    }

    /// <summary>Polls <paramref name="value"/> each frame until it is non-null; throws after <see cref="WaitLimit"/>.</summary>
    private static async Task<T> WaitForAsync<T>(Func<T?> value, string what)
        where T : class
    {
        var watch = Stopwatch.StartNew();
        while (true)
        {
            if (value() is { } found)
                return found;
            if (watch.Elapsed > WaitLimit)
                throw new TimeoutException($"timed out waiting for {what}");
            await Task.Delay(16);
        }
    }

    private static async Task<T> WithTimeout<T>(Task<T> task, TimeSpan limit, string what)
    {
        if (await Task.WhenAny(task, Task.Delay(limit)) != task)
            throw new TimeoutException($"timed out waiting for {what}");
        return await task;
    }

    private static async Task WithTimeout(Task task, TimeSpan limit, string what)
    {
        if (await Task.WhenAny(task, Task.Delay(limit)) != task)
            throw new TimeoutException($"timed out waiting for {what}");
        await task;
    }

    /// <summary>The nearest-rank percentile of <paramref name="sorted"/>, null when it is empty.</summary>
    private static double? Percentile(List<double> sorted, double p) =>
        sorted.Count == 0 ? null : sorted[Math.Clamp((int)Math.Ceiling(p * sorted.Count) - 1, 0, sorted.Count - 1)];

    /// <summary>spike.json; the gate's fields are checked by windows/scripts/qa-data.sh check.</summary>
    private sealed class SpikeResult
    {
        public long ParsedCommits { get; set; }
        public double? FirstRowsMs { get; set; }
        public double? FullLoadMs { get; set; }
        public double? FrameIntervalMedianMs { get; set; }
        public double? FrameIntervalP95Ms { get; set; }
        public double? FrameIntervalMaxMs { get; set; }
        public double? DrawMsP95 { get; set; }
        public long? LastRowIndex { get; set; }
        public bool? LastRowFullyDrawn { get; set; }
        public long? LastRowHitTest { get; set; }
        public bool[]? HitTestMatches { get; set; }
        public long[]? HitTestRows { get; set; }
        public double? RowTopErrorPx { get; set; }
        public int? ClickToHighlightFrames { get; set; }
        public long? ClickRow { get; set; }
        public string? Backdrop { get; set; }
        public bool? MicaSupported { get; set; }
        public double? ScrollSeconds { get; set; }
        public int? FrameCount { get; set; }
        public int? DrawCount { get; set; }
        public int? WheelStepsSent { get; set; }
        public string? ClientSize { get; set; }
        public double? RowHeight { get; set; }
        public double? ViewportHeight { get; set; }
        public string? Error { get; set; }
    }
}
#endif
