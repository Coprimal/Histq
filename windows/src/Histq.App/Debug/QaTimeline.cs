#if HISTQ_QA
using System.Diagnostics;
using Microsoft.UI.Xaml.Media;

namespace Histq.App;

/// <summary>
/// The launch's timeline (QA builds only): the first time each step happened, in ms since the process started (the
/// clock of the load probe, <c>Probes\load.json</c>'s breakdown). Steps: <c>onLaunched</c>, <c>windowFirstFrame</c>,
/// the first repo tab's <c>sessionStart</c>, <c>gitResolved</c>, <c>readEnv</c>, and its loader's <c>loaderEnv</c>,
/// <c>stashes</c>, <c>logSpawn</c>, <c>firstPageParsed</c>, <c>status</c>, <c>firstPagePosted</c>. Any thread.
/// </summary>
internal static class QaTimeline
{
    private static readonly Lock Gate = new();
    private static readonly Dictionary<string, double> Marks = new(StringComparer.Ordinal);
    private static readonly Stopwatch Clock = Stopwatch.StartNew();

    /// <summary>The process's age when the clock started (one wall-clock reading, as the spike harness).</summary>
    private static readonly TimeSpan StartAge = AgeNow();

    /// <summary>Ms since the process started.</summary>
    public static double Now() => Math.Round((StartAge + Clock.Elapsed).TotalMilliseconds, 1);

    /// <summary>Records <paramref name="step"/> now, unless it happened before.</summary>
    public static void Mark(string step)
    {
        double now = Now();
        lock (Gate)
            Marks.TryAdd(step, now);
    }

    /// <summary>When <paramref name="step"/> first happened; null when it has not.</summary>
    public static double? At(string step)
    {
        lock (Gate)
            return Marks.TryGetValue(step, out double ms) ? ms : null;
    }

    /// <summary>Marks <c>windowFirstFrame</c> on the first Rendering frame from now. UI thread.</summary>
    public static void WatchFirstFrame()
    {
        void OnRendering(object? sender, object e)
        {
            CompositionTarget.Rendering -= OnRendering;
            Mark("windowFirstFrame");
        }

        CompositionTarget.Rendering += OnRendering;
    }

    private static TimeSpan AgeNow()
    {
        using var process = Process.GetCurrentProcess();
        return DateTime.Now - process.StartTime;
    }
}
#endif
