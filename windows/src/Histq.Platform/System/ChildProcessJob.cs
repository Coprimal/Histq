using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.System.JobObjects;

// Not Histq.Platform.System: that namespace would hide System for every System.-qualified name under Histq.Platform.
namespace Histq.Platform.SystemServices;

/// <summary>
/// A Windows Job Object with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE for the git processes Histq starts: when Histq exits or
/// crashes, its handle closes and Windows kills every process in the job.
/// <para>
/// No breakaway limit is set, so every process a member starts joins the job too (git's own children). A descendant
/// that asks to break away from the job fails to start (ERROR_ACCESS_DENIED) instead of escaping.
/// </para>
/// <para>
/// Residual gap: a process is assigned after <see cref="Process.Start()"/> returns, so a child it starts before
/// <see cref="Assign"/> runs stays outside the job. Closing it needs a suspended start or a job list given at process
/// creation, which <see cref="Process"/> cannot do.
/// </para>
/// </summary>
/// <remarks>
/// Core cannot reference Platform, so the App hands <c>ChildProcessJob.Shared.Assign</c> to Core's <c>GitRunner</c> as
/// its <c>onStarted</c> callback.
/// </remarks>
public sealed class ChildProcessJob : IDisposable
{
    private static readonly Lazy<ChildProcessJob> s_shared = new(() => new ChildProcessJob());

    private readonly SafeFileHandle _job;

    /// <summary>The job for the app's lifetime, created on first use and never closed (closing it kills its members).</summary>
    public static ChildProcessJob Shared => s_shared.Value;

    /// <summary>A separate job; disposing it kills its processes. Throws <see cref="Win32Exception"/> when Windows refuses.</summary>
    internal unsafe ChildProcessJob()
    {
        _job = PInvoke.CreateJobObject(null, null);
        if (_job.IsInvalid)
            throw new Win32Exception(Marshal.GetLastPInvokeError());
        var limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (!PInvoke.SetInformationJobObject(
                (HANDLE)_job.DangerousGetHandle(), JOBOBJECTINFOCLASS.JobObjectExtendedLimitInformation, &limits,
                (uint)sizeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)))
        {
            var error = Marshal.GetLastPInvokeError();
            _job.Dispose();
            throw new Win32Exception(error);
        }
    }

    /// <summary>
    /// Puts a started process (and every process it starts from now on) in the job. A process that has already exited
    /// is ignored; any other failure throws <see cref="Win32Exception"/>, and GitRunner then kills the process tree
    /// (its <c>onStarted</c> contract), since it would outlive Histq.
    /// </summary>
    public void Assign(Process process)
    {
        ArgumentNullException.ThrowIfNull(process);
        if (PInvoke.AssignProcessToJobObject(_job, process.SafeHandle))
            return;
        // Read the error before HasExited, whose own calls overwrite it. An exited process fails with ERROR_ACCESS_DENIED.
        var error = Marshal.GetLastPInvokeError();
        if (process.HasExited)
            return;
        throw new Win32Exception(error);
    }

    /// <summary>Closes the job, which kills its processes. Never call it on <see cref="Shared"/>.</summary>
    public void Dispose() => _job.Dispose();
}
