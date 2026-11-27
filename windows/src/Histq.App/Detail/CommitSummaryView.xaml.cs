using Histq.App.Graph;
using Histq.App.Theme;
using Histq.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Animation;

namespace Histq.App.Detail;

/// <summary>
/// What the detail panel's summary shows of a graph row (the header part of CommitDetailPanel.swift at 6fa6d40), every
/// text made safe to show and to read through UI Automation (a commit's texts are the repo's, untrusted).
/// </summary>
/// <param name="Kind">"COMMIT", "STASH", "CHANGES" or "WORKTREE".</param>
/// <param name="Hash">The commit's or stash's full SHA; null for a WIP row.</param>
/// <param name="ParentsLabel">"Parent", "Parents" or, for a stash, "Base".</param>
/// <param name="Parents">The parents' full SHAs (a stash: only the commit it was made on).</param>
internal sealed record CommitSummary(
    string Kind, string Subject, string Body, string Author, string AuthorDetail, string Committer,
    string CommitterDetail, string? Hash, string ParentsLabel, IReadOnlyList<string> Parents)
{
    /// <summary>The most body lines shown: a hostile repository's huge message stays cheap.</summary>
    private const int MaxBodyLines = 200;

    /// <summary>
    /// The summary of <paramref name="item"/> in <paramref name="data"/>; null when it is not there any more. Pure, so it
    /// runs off the UI thread.
    /// </summary>
    public static CommitSummary? For(GraphItem item, GraphData data, GraphDateFormatter dates)
    {
        RepoSnapshot snapshot = data.Snapshot;
        switch (item.Kind)
        {
            case GraphItemKind.Commit:
                if (!snapshot.CommitIndex.TryGetValue(item.Id, out int index) || index >= snapshot.Commits.Count)
                    return null;
                Commit commit = snapshot.Commits[index];
                bool sameCommitter = string.Equals(commit.CommitterName, commit.AuthorName, StringComparison.Ordinal)
                    && string.Equals(commit.CommitterEmail, commit.AuthorEmail, StringComparison.Ordinal);
                bool hasCommitter = !sameCommitter && commit.CommitterName.Length > 0;
                return new CommitSummary(
                    "COMMIT", DisplayText.Sanitize(commit.Subject), BodyLines(commit.Body),
                    DisplayText.Sanitize(commit.AuthorName), Detail(commit.AuthorEmail, dates.Format(commit.AuthorDate)),
                    hasCommitter ? DisplayText.Sanitize(commit.CommitterName) + " · committer" : "",
                    hasCommitter ? Detail(commit.CommitterEmail, dates.Format(commit.CommitterDate)) : "",
                    DisplayText.Sanitize(commit.Hash), commit.Parents.Count == 1 ? "Parent" : "Parents",
                    [.. commit.Parents.Select(parent => DisplayText.Sanitize(parent))]);
            case GraphItemKind.Stash:
                if (snapshot.Stashes.FirstOrDefault(s => string.Equals(s.Hash, item.Id, StringComparison.Ordinal))
                    is not { } stash)
                {
                    return null;
                }

                return new CommitSummary(
                    "STASH", DisplayText.Sanitize(stash.Message), "", "", dates.Format(stash.Date), "", "",
                    DisplayText.Sanitize(stash.Hash), "Base", [DisplayText.Sanitize(stash.Base)]);
            case GraphItemKind.Worktree:
                WorktreeInfo? info = data.Worktrees.FirstOrDefault(
                    w => string.Equals(w.Path, item.Id, StringComparison.Ordinal));
                string name = DisplayText.Sanitize(info?.Name ?? PathFlavor.Host.LastComponent(item.Id));
                return new CommitSummary(
                    "WORKTREE", $"// WIP (on worktree {name})", Changes(info?.Changes), "",
                    DisplayText.Sanitize(item.Id), "", "", null, "", []);
            default:
                return new CommitSummary(
                    "CHANGES", "// WIP",
                    Changes(snapshot.Status is { } status ? WorktreeChanges.Of(status) : null), "", "", "", "", null, "",
                    []);
        }
    }

    /// <summary>The body line by line, each made safe to show, at most <see cref="MaxBodyLines"/> lines.</summary>
    private static string BodyLines(string body)
    {
        string[] lines = body.Trim().Split('\n', MaxBodyLines + 1);
        IEnumerable<string> shown = lines.Take(MaxBodyLines).Select(line => DisplayText.Sanitize(line.TrimEnd('\r')));
        string text = string.Join("\n", shown);
        return lines.Length > MaxBodyLines ? text + "\n…" : text;
    }

    private static string Detail(string email, string date)
    {
        string shown = DisplayText.Sanitize(email);
        return shown.Length == 0 ? date : shown + " · " + date;
    }

    private static string Changes(WorktreeChanges? changes) =>
        changes is { KindSummary: { Length: > 0 } summary } ? summary : "No changes";
}

/// <summary>
/// The detail panel's summary of the selected graph row. <see cref="Show"/> switches to the placeholder in the same
/// frame (the click's), starts the spinner's delay (SpinnerDelay; a summary in by then never shows it) and makes the
/// summary off the UI thread; it shows once made, unless another row was selected meanwhile. A parent's link selects
/// its row (<see cref="ParentClicked"/>).
/// </summary>
public sealed partial class CommitSummaryView : UserControl
{
    private readonly DispatcherQueueTimer _spinnerTimer;

    /// <summary>New for each <see cref="Show"/>: an older summary is dropped.</summary>
    private int _token;

    private bool _released;

    /// <summary>What shows when a summary cannot be made.</summary>
    private static readonly CommitSummary Unavailable = new("", "Not available", "", "", "", "", "", null, "", []);

    public CommitSummaryView()
    {
        InitializeComponent();
        Spinner.OpacityTransition = new ScalarTransition { Duration = PaletteResources.TimeSpan("MotionStandardDuration") };
        _spinnerTimer = DispatcherQueue.GetForCurrentThread().CreateTimer();
        _spinnerTimer.Interval = PaletteResources.TimeSpan("SpinnerDelay");
        _spinnerTimer.IsRepeating = false;
        _spinnerTimer.Tick += (_, _) => ShowSpinner();
    }

    /// <summary>A parent's link was clicked: its full SHA.</summary>
    internal event Action<string>? ParentClicked;

    /// <summary>
    /// Shows <paramref name="item"/> of <paramref name="data"/>: the placeholder now, the summary once made off the UI
    /// thread. UI thread.
    /// </summary>
    internal void Show(GraphItem item, GraphData data, GraphDateFormatter dates) => Show(item, data, dates, true);

    /// <summary>The same row in new data (a WIP row's counts changed): its summary made again, shown in place of the old
    /// one without the placeholder. UI thread.</summary>
    internal void Refresh(GraphItem item, GraphData data, GraphDateFormatter dates) => Show(item, data, dates, false);

    private void Show(GraphItem item, GraphData data, GraphDateFormatter dates, bool placeholder)
    {
        int token = ++_token;
        if (placeholder)
            ShowPlaceholder();
        DispatcherQueue dispatcher = DispatcherQueue;
        _ = Task.Run(() =>
        {
            CommitSummary? summary;
            try
            {
                summary = CommitSummary.For(item, data, dates);
            }
            catch (Exception error)
            {
                System.Diagnostics.Debug.WriteLine($"CommitSummaryView: summary not made: {error.Message}");
                summary = null;
            }

            dispatcher.TryEnqueue(() =>
            {
                // A row gone meanwhile, or a summary that could not be made: a short line, never a spinner left on.
                if (token == _token && !_released)
                    Fill(summary ?? Unavailable);
            });
        });
    }

    /// <summary>The view is gone: no summary is shown any more and the spinner's timer stops.</summary>
    internal void Release()
    {
        _released = true;
        _spinnerTimer.Stop();
    }

#if HISTQ_QA
    /// <summary>The placeholder is up.</summary>
    internal bool QaShowsPlaceholder => Placeholder.Visibility == Visibility.Visible;

    /// <summary>A summary is shown.</summary>
    internal bool QaShowsSummary => SummaryContent.Visibility == Visibility.Visible;
#endif

    private void ShowPlaceholder()
    {
        SummaryContent.Visibility = Visibility.Collapsed;
        Placeholder.Visibility = Visibility.Visible;
        Spinner.IsActive = false;
        Spinner.Opacity = 0;
        _spinnerTimer.Stop();
        _spinnerTimer.Start();
    }

    /// <summary>The summary is still being made after SpinnerDelay: the spinner fades in.</summary>
    private void ShowSpinner()
    {
        if (_released || Placeholder.Visibility != Visibility.Visible)
            return;
        Spinner.IsActive = true;
        Spinner.Opacity = 1;
    }

    private void Fill(CommitSummary summary)
    {
        _spinnerTimer.Stop();
        KindText.Text = summary.Kind;
        SubjectText.Text = summary.Subject;
        SetText(BodyText, summary.Body);
        SetText(AuthorText, summary.Author);
        SetText(AuthorDetailText, summary.AuthorDetail);
        AuthorRow.Visibility = Shown(summary.Author.Length > 0 || summary.AuthorDetail.Length > 0);
        SetText(CommitterText, summary.Committer);
        SetText(CommitterDetailText, summary.CommitterDetail);
        CommitterRow.Visibility = Shown(summary.Committer.Length > 0);
        HashText.Text = summary.Hash ?? "";
        HashRow.Visibility = Shown(summary.Hash is not null);
        ParentsLabel.Text = summary.ParentsLabel;
        ParentsPanel.Children.Clear();
        foreach (string parent in summary.Parents)
        {
            var link = new HyperlinkButton
            {
                Content = parent.Length > 7 ? parent[..7] : parent,
                Padding = new Thickness(4, 0, 4, 0),
                FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas"),
            };
            ToolTipService.SetToolTip(link, "Show " + parent);
            AutomationProperties.SetName(link, "Show parent " + parent);
            link.Click += (_, _) => ParentClicked?.Invoke(parent);
            ParentsPanel.Children.Add(link);
        }

        ParentsRow.Visibility = Shown(summary.Parents.Count > 0);
        Spinner.IsActive = false;
        Spinner.Opacity = 0;
        Placeholder.Visibility = Visibility.Collapsed;
        SummaryContent.Visibility = Visibility.Visible;
        SummaryContent.ChangeView(null, 0, null, disableAnimation: true);
    }

    private static void SetText(TextBlock block, string text)
    {
        block.Text = text;
        block.Visibility = Shown(text.Length > 0);
    }

    private static Visibility Shown(bool shown) => shown ? Visibility.Visible : Visibility.Collapsed;
}
