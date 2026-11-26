using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;
using Windows.Graphics;

namespace Histq.App.Shell;

/// <summary>
/// The title bar's input regions (design header-and-tab-row.md §1): every interactive element is a Passthrough
/// rect; everything else in the title bar stays the system caption (drag, double-click maximizes, right-click
/// system menu). Rects are in physical pixels of the window's client area. Recomputed on the title bar's Loaded and
/// SizeChanged, on XamlRoot.Changed (scale) and on <see cref="Refresh"/> (tab-model change, track scroll).
/// </summary>
public sealed class TitleBarRegions
{
    private readonly Window _window;
    private readonly FrameworkElement _titleBar;
    private readonly ColumnDefinition _leftInsetColumn;
    private readonly ColumnDefinition _rightInsetColumn;
    private readonly Func<IEnumerable<FrameworkElement>> _interactiveElements;
    private XamlRoot? _xamlRoot;
    private bool _closed;

    /// <param name="window">The window whose content extends into the title bar.</param>
    /// <param name="titleBar">The title bar's root element; rects are clipped to its bounds minus the insets.</param>
    /// <param name="leftInsetColumn">The column kept under the caption buttons in right-to-left layouts.</param>
    /// <param name="rightInsetColumn">The column kept under the caption buttons in left-to-right layouts.</param>
    /// <param name="interactiveElements">The elements that take input, queried again on every update.</param>
    public TitleBarRegions(
        Window window,
        FrameworkElement titleBar,
        ColumnDefinition leftInsetColumn,
        ColumnDefinition rightInsetColumn,
        Func<IEnumerable<FrameworkElement>> interactiveElements)
    {
        _window = window;
        _titleBar = titleBar;
        _leftInsetColumn = leftInsetColumn;
        _rightInsetColumn = rightInsetColumn;
        _interactiveElements = interactiveElements;

        titleBar.Loaded += OnTitleBarLoaded;
        titleBar.SizeChanged += OnTitleBarSizeChanged;
        window.Closed += OnWindowClosed;
    }

    /// <summary>Sets the inset columns and the Passthrough rects from the current layout.</summary>
    public void Refresh()
    {
        if (_closed || !_window.ExtendsContentIntoTitleBar || _titleBar.XamlRoot is not { } root)
            return;

        double scale = root.RasterizationScale;
        AppWindowTitleBar bar = _window.AppWindow.TitleBar;
        double leftInset = bar.LeftInset / scale;
        double rightInset = bar.RightInset / scale;
        _leftInsetColumn.Width = new GridLength(leftInset);
        _rightInsetColumn.Width = new GridLength(rightInset);

        // Never over the caption buttons: clip to the title bar minus the caption-button insets.
        Rect barBounds = BoundsInWindow(_titleBar);
        var clip = new Rect(
            barBounds.X + leftInset,
            barBounds.Y,
            Math.Max(0, barBounds.Width - leftInset - rightInset),
            barBounds.Height);
        var rects = new List<RectInt32>();
        foreach (FrameworkElement element in _interactiveElements())
        {
            if (element.XamlRoot is null || element.Visibility != Visibility.Visible
                || element.ActualWidth <= 0 || element.ActualHeight <= 0)
                continue;
            if (ToPhysical(BoundsInWindow(element), clip, scale) is { } rect)
                rects.Add(rect);
        }

        InputNonClientPointerSource.GetForWindowId(_window.AppWindow.Id)
            .SetRegionRects(NonClientRegionKind.Passthrough, rects.ToArray());
    }

    private void OnTitleBarLoaded(object sender, RoutedEventArgs e)
    {
        // XamlRoot is null before Loaded; its Changed event reports scale changes (window moved to another display).
        if (_xamlRoot is null && _titleBar.XamlRoot is { } root)
        {
            _xamlRoot = root;
            root.Changed += OnXamlRootChanged;
        }
        Refresh();
    }

    private void OnTitleBarSizeChanged(object sender, SizeChangedEventArgs e) => Refresh();

    private void OnXamlRootChanged(XamlRoot sender, XamlRootChangedEventArgs args) => Refresh();

    private void OnWindowClosed(object sender, WindowEventArgs args) => _closed = true;

    private static Rect BoundsInWindow(FrameworkElement element) =>
        element.TransformToVisual(null).TransformBounds(new Rect(0, 0, element.ActualWidth, element.ActualHeight));

    /// <summary>
    /// The part of <paramref name="bounds"/> inside <paramref name="clip"/>, in physical pixels, or null when empty.
    /// Edges are rounded (not origin and size) so neighbouring tabs never leave a 1 px caption sliver between them.
    /// </summary>
    private static RectInt32? ToPhysical(Rect bounds, Rect clip, double scale)
    {
        double left = Math.Max(bounds.X, clip.X);
        double top = Math.Max(bounds.Y, clip.Y);
        double right = Math.Min(bounds.X + bounds.Width, clip.X + clip.Width);
        double bottom = Math.Min(bounds.Y + bounds.Height, clip.Y + clip.Height);

        int x0 = (int)Math.Round(left * scale);
        int y0 = (int)Math.Round(top * scale);
        int x1 = (int)Math.Round(right * scale);
        int y1 = (int)Math.Round(bottom * scale);
        if (x1 <= x0 || y1 <= y0)
            return null;
        return new RectInt32(x0, y0, x1 - x0, y1 - y0);
    }
}
