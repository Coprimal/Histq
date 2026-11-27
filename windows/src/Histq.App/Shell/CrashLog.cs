using System.Globalization;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using Histq.Core;
using Microsoft.UI.Xaml;

namespace Histq.App.Shell;

/// <summary>
/// The crash log, <c>&lt;state folder&gt;\Logs\crash.log</c>, in every build: an exception nothing handles (XAML's
/// <see cref="Application.UnhandledException"/>, the AppDomain's, an unobserved task's) is appended there with its type,
/// HResult, message and full stack, inner exceptions included, and the app then goes down as it would anyway (the
/// handlers never mark it handled). <see cref="Recovered"/> appends an exception the app gets past but must not hide (a
/// tab row decoration drawn plainly), once per kind. Each entry is one synchronous append under a short lock wait, so a
/// dying process still writes it and no thread waits long; a failed write is dropped. Only the exceptions' own text is
/// written (their stacks name local source and module paths), nothing else about the tabs.
/// </summary>
internal static class CrashLog
{
    private static readonly Lock Gate = new();
    private static readonly HashSet<string> Recorded = new(StringComparer.Ordinal);
    private static StatePaths? s_paths;

    /// <summary>The last exception thrown anywhere (first chance): a fatal entry adds it when XAML handed on another
    /// one (rebuilt from its HResult, with no stack). Only the reference is kept.</summary>
    private static volatile Exception? s_lastThrown;

    /// <summary>Logs the AppDomain's unhandled and the unobserved task exceptions from now on; call first in Main.</summary>
    public static void Install(StatePaths paths)
    {
        s_paths = paths;
        AppDomain.CurrentDomain.FirstChanceException += (_, e) => s_lastThrown = e.Exception;
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Write(
            "AppDomain.UnhandledException", e.ExceptionObject as Exception,
            e.ExceptionObject is Exception ? null : e.ExceptionObject?.ToString(), fatal: true);
        // Logged only: an unobserved task exception does not end the process (.NET's default is kept).
        TaskScheduler.UnobservedTaskException += (_, e) =>
            Write("TaskScheduler.UnobservedTaskException", e.Exception, null, fatal: false);
    }

    /// <summary>Logs XAML's unhandled exceptions (an event handler's, a layout pass's) for <paramref name="app"/>; the
    /// exception stays unhandled, so the app still ends.</summary>
    public static void Watch(Application app) =>
        app.UnhandledException += (_, e) => Write("Application.UnhandledException", e.Exception, e.Message, fatal: true);

    /// <summary>An exception the app got past (<paramref name="where"/> says what it did instead), logged once per
    /// place, type and HResult.</summary>
    public static void Recovered(string where, Exception error)
    {
        string kind = $"{where}|{error.GetType().FullName}|{error.HResult}";
        lock (Recorded)
        {
            if (!Recorded.Add(kind))
                return;
        }

        Write($"Recovered: {where}", error, null, fatal: false);
    }

    private static void Write(string source, Exception? error, string? message, bool fatal)
    {
        if (s_paths is not { } paths)
            return;
        try
        {
            var text = new StringBuilder(Entry(source, error, message));
            if (fatal && s_lastThrown is { } thrown && (error is null || !Chain(error, 0).Any(item => ReferenceEquals(item.Exception, thrown))))
                text.Append("Last exception thrown before it (first chance):\n").Append(Entry("first chance", thrown, null));

            if (!Gate.TryEnter(TimeSpan.FromSeconds(1)))
                return;
            try
            {
                string file = Path.Combine(paths.Directory("Logs"), "crash.log");
                using var stream = new FileStream(file, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
                byte[] bytes = Encoding.UTF8.GetBytes(text.ToString());
                stream.Write(bytes, 0, bytes.Length);
                stream.Flush(flushToDisk: true);
            }
            finally
            {
                Gate.Exit();
            }
        }
        catch (Exception)
        {
            // The log is a last resort: a failure to write it must never be what ends the app.
        }
    }

    private static string Entry(string source, Exception? error, string? message)
    {
        var text = new StringBuilder();
        text.Append(CultureInfo.InvariantCulture,
            $"=== {DateTime.UtcNow:yyyy-MM-ddTHH:mm:ss.fffZ} {source} (Histq {Version()}, {RuntimeInformation.ProcessArchitecture}, {RuntimeInformation.OSDescription})\n");
        if (!string.IsNullOrEmpty(message) && !string.Equals(message, error?.Message, StringComparison.Ordinal))
            text.Append(CultureInfo.InvariantCulture, $"Message: {message}\n");
        if (error is null)
            return text.Append('\n').ToString();

        // Every exception in the chain with its HResult (ToString leaves HResults out), then the full ToString.
        foreach ((Exception exception, int depth) in Chain(error, 0))
        {
            text.Append(' ', 2 * depth).Append(CultureInfo.InvariantCulture,
                $"{exception.GetType().FullName} (HResult 0x{exception.HResult:X8}): {exception.Message}\n");
        }

        return text.Append(error).Append("\n\n").ToString();
    }

    /// <summary>The exception and its inner ones, depth first (an AggregateException's every inner one).</summary>
    private static IEnumerable<(Exception Exception, int Depth)> Chain(Exception error, int depth)
    {
        yield return (error, depth);
        if (depth >= 8)
            yield break;
        IEnumerable<Exception> inner = error is AggregateException aggregate
            ? aggregate.InnerExceptions
            : error.InnerException is { } one ? [one] : [];
        foreach (Exception child in inner)
        {
            foreach ((Exception Exception, int Depth) item in Chain(child, depth + 1))
                yield return item;
        }
    }

    private static string Version() =>
        typeof(CrashLog).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
        ?? "0.0.0";
}
