// The app's preferences: `preferences.json` in the state folder (StatePaths.Root, so a QA state dir has its own), one
// JSON object holding the keys the user set, under the Mac's PrefKey names; a key never set reads as its default.
// Ported from AppState.swift (Preferences, PrefKey) at 6fa6d40, where UserDefaults keeps them. Per-machine state:
// nothing is imported from the Mac.
using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Histq.Core;

/// <summary>Every preference key of the app, declared once with its default (<see cref="PrefKeys"/>). The stored name
/// is the Mac's raw value: the member name with a lower-case first letter (<c>RowDensity</c> is <c>rowDensity</c>).
/// Choices are stored as strings.</summary>
public enum PrefKey
{
    DateFormat,
    RowDensity,
    CommitOrder,
    LaneColors,
    TextSize,
    AvatarMode,
    AuthorEmojis,
    PullMode,
    AutoStash,
    AutoFetchMinutes,
    PruneOnFetch,
    AutoUpdateSubmodules,
    MergeTool,
    GitPath,
    DefaultProfileID,
    TabPosition,
    DefaultTabEmoji,
    DefaultTabIconColor,
    NativeTabsOnTop,
    PanelWidths,
    HistoryPanelWidth,
    LayoutPreset,
    CardBorders,
    StackedSplit,
    PresetBeforeFocus,
    ColumnsWidths,
    ShowSidebar,
    ShowDetail,
    SidebarSectionOrder,
    HiddenSidebarSections,
    GraphColumnWidths,
    GraphShowMessage,
    GraphShowAuthor,
    GraphShowDate,
    GraphFadeOtherWorktrees,
    TerminalFontName,
    TerminalFontSize,
    TerminalShell,
    TerminalScrollback,
    TerminalCursor,
    TerminalBoldText,
    TerminalOpenWithNewTab,
    RecentRepos,
    RecentWorkspaces,
    FileListMode,
    CommitShowsAllFiles,
    ShowFileSizes,
    CommitBoxPosition,
    StagedPosition,
    DiffIgnoreWhitespace,
    DiffWrapLines,
    DiffDefaultMode,
    BlameWrapLines,
    CodeFontSize,
    AiShowFeatures,
    AiProvider,
    AiModels,
    AiCustomBaseURL,
    AiResponseLanguage,
    AiCommitLanguage,
    AiCommitSummaryOnly,
    AiCommitInstructions,
    AiExplainInstructions,
    AiConflictInstructions,
    AiPullRequestInstructions,
    AiChatBubblePosition,
    AiChatCardWidth,
    AiChatCardHeight,
    AiChatBubbleHidden,
    AiChatReadsRepository,
    ToastLevel,
    HiddenRefs,
    OnboardingDone,
}

public static class PrefKeys
{
    extension(PrefKey key)
    {
        /// <summary>The stored key, as on the Mac (<c>rowDensity</c>).</summary>
        public string Name
        {
            get
            {
                var name = key.ToString();
                return char.ToLowerInvariant(name[0]) + name[1..];
            }
        }

        /// <summary>The value the key has until the user sets it (AppState.swift's <c>defaultValue</c>).</summary>
        public object Default => key switch
        {
            PrefKey.DateFormat => "MM/dd/yy @ HH:mm",
            PrefKey.RowDensity => "regular",
            PrefKey.CommitOrder => "date",
            PrefKey.LaneColors => "vivid",
            PrefKey.TextSize => "regular",
            PrefKey.AvatarMode => "generated",
            PrefKey.AuthorEmojis => new Dictionary<string, string>(),
            PrefKey.PullMode => "fastForward",
            PrefKey.AutoStash => "ask",
            PrefKey.AutoFetchMinutes => 3,
            PrefKey.PruneOnFetch => false,
            PrefKey.AutoUpdateSubmodules => true,
            PrefKey.MergeTool => "",
            PrefKey.GitPath => "",
            PrefKey.DefaultProfileID => "",
            PrefKey.TabPosition => "top",
            PrefKey.DefaultTabEmoji => "",
            PrefKey.DefaultTabIconColor => -1,
            PrefKey.NativeTabsOnTop => false,
            PrefKey.PanelWidths => "",
            PrefKey.HistoryPanelWidth => 0.0,
            PrefKey.LayoutPreset => "classic",
            PrefKey.StackedSplit => 0.45,
            PrefKey.PresetBeforeFocus => "classic",
            PrefKey.CardBorders => true,
            PrefKey.ColumnsWidths => "",
            PrefKey.ShowSidebar or PrefKey.ShowDetail => true,
            PrefKey.SidebarSectionOrder or PrefKey.HiddenSidebarSections => "",
            PrefKey.GraphColumnWidths => "",
            PrefKey.GraphShowMessage or PrefKey.GraphShowAuthor or PrefKey.GraphShowDate => true,
            PrefKey.GraphFadeOtherWorktrees => false,
            PrefKey.TerminalFontName => "",
            PrefKey.TerminalFontSize => 12.0,
            PrefKey.TerminalShell => "",
            PrefKey.TerminalScrollback => 10_000,
            PrefKey.TerminalCursor => "block",
            PrefKey.TerminalBoldText => false,
            PrefKey.TerminalOpenWithNewTab => false,
            PrefKey.RecentRepos or PrefKey.RecentWorkspaces => Array.Empty<string>(),
            PrefKey.FileListMode => "tree",
            PrefKey.CommitShowsAllFiles => false,
            PrefKey.ShowFileSizes => true,
            PrefKey.CommitBoxPosition => "bottom",
            PrefKey.StagedPosition => "below",
            PrefKey.DiffIgnoreWhitespace or PrefKey.DiffWrapLines => false,
            PrefKey.DiffDefaultMode => "diff",
            PrefKey.BlameWrapLines => false,
            PrefKey.CodeFontSize => 12.0,
            PrefKey.AiShowFeatures => true,
            PrefKey.AiProvider => "openAI",
            PrefKey.AiModels => new Dictionary<string, string>(),
            PrefKey.AiCustomBaseURL => "",
            PrefKey.AiResponseLanguage => "english",
            PrefKey.AiCommitLanguage => "english",
            PrefKey.AiCommitSummaryOnly => false,
            PrefKey.AiCommitInstructions or PrefKey.AiExplainInstructions or PrefKey.AiConflictInstructions
                or PrefKey.AiPullRequestInstructions => "",
            PrefKey.AiChatBubblePosition => 1.0,
            PrefKey.AiChatCardWidth or PrefKey.AiChatCardHeight => 0.0,
            PrefKey.AiChatBubbleHidden => false,
            PrefKey.AiChatReadsRepository => true,
            PrefKey.ToastLevel => "all",
            PrefKey.HiddenRefs => new Dictionary<string, string[]>(),
            PrefKey.OnboardingDone => false,
            _ => throw new ArgumentOutOfRangeException(nameof(key), key, "Not a preference key."),
        };
    }
}

/// <summary>
/// The preferences of one state folder, read once and written (atomically) on every change. Thread-safe. Keys this build
/// does not know (a later build's) are kept as they are.
/// </summary>
public sealed class Preferences
{
    public const string FileName = "preferences.json";

    private readonly Lock gate = new();
    private readonly JsonObject values;

    private Preferences(string file, JsonObject values)
    {
        File = file;
        this.values = values;
    }

    /// <summary>The <c>preferences.json</c> it reads and writes.</summary>
    public string File { get; }

    /// <summary><c>preferences.json</c> in the state folder.</summary>
    public static string In(StatePaths paths) => Path.Combine(paths.Root, FileName);

    /// <summary>
    /// The preferences in <paramref name="file"/>; empty (every key at its default) when it is missing or not a JSON
    /// object. A toast level of "off" (an earlier build's) becomes "errors": a failure always shows its toast.
    /// </summary>
    public static Preferences Load(string file)
    {
        JsonObject values;
        try
        {
            values = JsonNode.Parse(System.IO.File.ReadAllBytes(file)) as JsonObject ?? [];
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        {
            values = [];
        }

        var preferences = new Preferences(file, values);
        if (string.Equals(preferences.Get<string>(PrefKey.ToastLevel), "off", StringComparison.Ordinal))
        {
            preferences.Set(PrefKey.ToastLevel, "errors");
        }

        return preferences;
    }

    /// <summary>The value of <paramref name="key"/> as <typeparamref name="T"/>: the stored one, else (never set, or
    /// stored as another type) its default.</summary>
    public T Get<T>(PrefKey key)
    {
        lock (gate)
        {
            if (values[key.Name] is { } node)
            {
                try
                {
                    if (node.Deserialize<T>(SwiftJson.Options) is { } stored)
                    {
                        return stored;
                    }
                }
                catch (Exception error) when (error is JsonException or NotSupportedException or InvalidOperationException)
                {
                }
            }
        }

        return JsonSerializer.SerializeToNode(key.Default, SwiftJson.Options).Deserialize<T>(SwiftJson.Options)
            ?? throw new InvalidOperationException($"{key.Name} has no default of type {typeof(T).Name}.");
    }

    /// <summary>Stores <paramref name="value"/> for <paramref name="key"/> and writes the file; a failed write keeps the
    /// value for this run.</summary>
    public void Set<T>(PrefKey key, T value)
    {
        lock (gate)
        {
            values[key.Name] = JsonSerializer.SerializeToNode(value, SwiftJson.Options);
            try
            {
                var element = JsonSerializer.SerializeToElement(values, SwiftJson.Options);
                AtomicFile.Write(File, SwiftJson.Write(element, SwiftJsonFormatting.PrettyPrinted | SwiftJsonFormatting.SortedKeys));
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                Debug.WriteLine($"preferences.json not saved: {error.Message}");
            }
        }
    }
}
