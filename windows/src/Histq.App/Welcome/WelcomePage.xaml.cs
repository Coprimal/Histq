using System.Diagnostics;
using System.Globalization;
using Histq.App.Theme;
using Histq.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Histq.App.Welcome;

/// <summary>
/// The page of a tab with no repository (ported from WelcomeModel and WelcomeView, App/Welcome/WelcomeView.swift at
/// 6fa6d40, their open and recent parts). Open folder and a click on a recent repository open it in this tab at once
/// (<see cref="Shell.WindowManager"/>: the tab becomes the repo's, which swaps this page out). Each page checks once that
/// a usable git is found (<see cref="GitExecutable.ResolveAsync"/>, which honours the gitPath preference) off the UI
/// thread: "checking" from the first frame, its spinner shown after SpinnerDelay; a problem shows why, with Choose
/// git…, Use automatic git and Check again. Opening never waits for the check, as on the Mac.
/// </summary>
public sealed partial class WelcomePage : UserControl
{
    private readonly MainWindow _window;
    private readonly DispatcherQueueTimer _spinnerTimer;

    /// <summary>The latest git check: a check's result shows only while it is still the latest.</summary>
    private int _check;

    private bool _isChecking;

    internal WelcomePage(MainWindow window)
    {
        _window = window;
        InitializeComponent();

        GitCheckingRing.OpacityTransition = new ScalarTransition
        {
            Duration = PaletteResources.TimeSpan("MotionStandardDuration"),
        };
        _spinnerTimer = DispatcherQueue.GetForCurrentThread().CreateTimer();
        _spinnerTimer.Interval = PaletteResources.TimeSpan("SpinnerDelay");
        _spinnerTimer.IsRepeating = false;
        _spinnerTimer.Tick += (_, _) => ShowSpinner();

        OpenFolderButton.Click += (_, _) => _window.Manager.ChooseFolder(_window);
        ChooseGitButton.Click += (_, _) => _ = ChooseGitAsync();
        AutomaticGitButton.Click += (_, _) => CheckGit(_window.Manager.SetPreference(PrefKey.GitPath, string.Empty));
        CheckAgainButton.Click += (_, _) => CheckGit(Task.CompletedTask);
        RecentList.ItemClick += OnRecentClick;
        Unloaded += (_, _) => _spinnerTimer.Stop();

        ShowRecent();
        CheckGit(Task.CompletedTask);
    }

    // Git check

    /// <summary>
    /// Shows "checking" at once, then looks for git off the UI thread once <paramref name="after"/> (a queued
    /// preference write) is done, so it reads the gitPath just saved. A newer check supersedes this one.
    /// </summary>
    private void CheckGit(Task after) => _ = CheckGitAsync(after);

    private async Task CheckGitAsync(Task after)
    {
        int check = ++_check;
        ShowChecking();

        Preferences preferences = _window.Manager.Preferences;
        (GitExecutableError? problem, bool hasOverride) = await Task.Run(async () =>
        {
            await after.ConfigureAwait(false);
            // Read here, never on the UI thread: a write holds the preferences' lock while it saves the file.
            string overridePath = preferences.Get<string>(PrefKey.GitPath);
            bool hasOverride = !string.IsNullOrWhiteSpace(overridePath);
            try
            {
                await GitExecutable.ResolveAsync(overridePath).ConfigureAwait(false);
                return ((GitExecutableError?)null, hasOverride);
            }
            catch (GitExecutableError error)
            {
                return (error, hasOverride);
            }
            catch (Exception error)
            {
                Trace.WriteLine($"Histq: git check failed: {error.Message}");
                return (GitExecutableError.NotFound(), hasOverride);
            }
        });

        // The await resumes on the UI thread; a later check (Check again) wins.
        if (check != _check)
            return;
        ShowGitResult(problem, hasOverride);
    }

    /// <summary>"Checking git…" at once, its spinner after SpinnerDelay; a problem shown before hides until the result,
    /// as the Mac's checking state.</summary>
    private void ShowChecking()
    {
        _isChecking = true;
        GitProblemCard.Visibility = Visibility.Collapsed;
        GitCheckingRow.Visibility = Visibility.Visible;
        _spinnerTimer.Stop();
        _spinnerTimer.Start();
    }

    /// <summary>The check is still running after SpinnerDelay: its spinner fades in.</summary>
    private void ShowSpinner()
    {
        if (!_isChecking)
            return;
        GitCheckingRing.IsActive = true;
        GitCheckingRing.Opacity = 1;
    }

    private void ShowGitResult(GitExecutableError? problem, bool hasOverride)
    {
        _isChecking = false;
        _spinnerTimer.Stop();
        GitCheckingRing.IsActive = false;
        GitCheckingRing.Opacity = 0;
        GitCheckingRow.Visibility = Visibility.Collapsed;

        if (problem is null)
        {
            GitProblemCard.Visibility = Visibility.Collapsed;
            return;
        }

        GitProblemTitle.Text = ProblemTitle(problem);
        GitProblemText.Text = ProblemExplanation(problem);
        AutomationProperties.SetName(GitProblemCard, GitProblemTitle.Text);
        AutomaticGitButton.Visibility = hasOverride ? Visibility.Visible : Visibility.Collapsed;
        GitProblemCard.Visibility = Visibility.Visible;
    }

    /// <summary>Choose git…: a git.exe picked (owned by this window) becomes the gitPath preference, then git is checked
    /// again.</summary>
    private async Task ChooseGitAsync()
    {
        string? path = await _window.Manager.PickGitAsync(_window);
        if (path is null)
            return;
        CheckGit(_window.Manager.SetPreference(PrefKey.GitPath, path));
    }

    private static string ProblemTitle(GitExecutableError error) => error.Kind switch
    {
        GitExecutableErrorKind.TooOld => $"Git {error.Version} is too old",
        GitExecutableErrorKind.NotExecutable => "The chosen git cannot run",
        GitExecutableErrorKind.UnrecognizedVersion => "Git did not report its version",
        _ => "Git was not found",
    };

    /// <summary>The Mac's explanations, with Git for Windows in place of the Command Line Tools.</summary>
    private static string ProblemExplanation(GitExecutableError error) => error.Kind switch
    {
        GitExecutableErrorKind.TooOld =>
            $"Histq needs git {GitExecutable.MinimumVersion} or later. Install a newer Git for Windows, or choose a "
                + "git.exe.",
        GitExecutableErrorKind.NotExecutable =>
            $"{error.ExecutablePath} is not an executable git. Choose another one, or let Histq detect git "
                + "automatically.",
        GitExecutableErrorKind.UnrecognizedVersion =>
            $"Running git --version printed \"{error.Output}\". Choose another git.",
        _ => "No git was found on your PATH or in Git for Windows' usual folders. Install Git for Windows, or choose "
            + "a git.exe.",
    };

    // Recent repositories

    /// <summary>The recent repos as rows: the folder's name, then its parent folder. String work only, so a UNC entry
    /// is never probed until it is picked. <see cref="Shell.WindowManager"/> calls it again once an open elsewhere has
    /// saved the list.</summary>
    internal void ShowRecent()
    {
        PathFlavor flavor = PathFlavor.Host;
        IReadOnlyList<string> paths = _window.Manager.RecentRepos.Paths;
        RecentList.Items.Clear();
        foreach (string path in paths)
            RecentList.Items.Add(RecentRow(flavor, path));
        RecentCount.Text = paths.Count.ToString(CultureInfo.InvariantCulture);
        RecentEmptyText.Visibility = paths.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private static ListViewItem RecentRow(PathFlavor flavor, string path)
    {
        string name = DisplayText.Sanitize(flavor.LastComponent(path));
        var nameText = new TextBlock
        {
            Text = name,
            MaxWidth = PaletteResources.Double("RecentNameMaxWidth"),
            FontSize = 13,
            VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        var folderText = new TextBlock
        {
            Text = DisplayText.Sanitize(flavor.Parent(path)),
            FontSize = 12,
            Opacity = 0.6,
            VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        var icon = new FontIcon
        {
            Glyph = "",
            FontSize = PaletteResources.Double("CommandIconSize"),
            VerticalAlignment = VerticalAlignment.Center,
        };
        var row = new Grid { ColumnSpacing = 8, Tag = path };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Grid.SetColumn(nameText, 1);
        Grid.SetColumn(folderText, 2);
        row.Children.Add(icon);
        row.Children.Add(nameText);
        row.Children.Add(folderText);

        var item = new ListViewItem
        {
            Content = row,
            Tag = path,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
        };
        AutomationProperties.SetName(item, name);
        string shownPath = DisplayText.Sanitize(path);
        AutomationProperties.SetHelpText(item, shownPath);
        ToolTipService.SetToolTip(item, shownPath);
        return item;
    }

    /// <summary>A click on a recent repository opens it in this tab at once (never probed first, as on the Mac).</summary>
    private void OnRecentClick(object sender, ItemClickEventArgs args)
    {
        if (args.ClickedItem is FrameworkElement { Tag: string path })
            _window.Manager.OpenRepo(_window, path);
    }
}
