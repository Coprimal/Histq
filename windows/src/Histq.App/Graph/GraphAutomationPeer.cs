using System.Globalization;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Windows.Foundation;

namespace Histq.App.Graph;

/// <summary>
/// <see cref="GraphCanvas"/> in UI Automation: a List whose items are the rows on screen (name = the subject, position
/// in set = the row index + 1), so vmpal_tree can read the graph. Rows off screen have no peer.
/// <para>
/// The list has the Scroll pattern (vertical only), mapped to the canvas's drawn scroll bar, so assistive tech and
/// vmpal can read and set the position. It is read on request only: no property change event is raised per scroll step.
/// </para>
/// </summary>
public sealed partial class GraphAutomationPeer : FrameworkElementAutomationPeer, IScrollProvider
{
    private readonly GraphCanvas _canvas;

    /// <summary>The visible rows' peers, kept while their row stays on screen so UI Automation sees the same element.</summary>
    private readonly Dictionary<long, GraphRowAutomationPeer> _rowPeers = [];

    private readonly List<long> _gone = [];

    public GraphAutomationPeer(GraphCanvas owner)
        : base(owner) => _canvas = owner;

    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.List;

    protected override string GetClassNameCore() => nameof(GraphCanvas);

    protected override bool IsControlElementCore() => true;

    public bool HorizontallyScrollable => false;

    public double HorizontalScrollPercent => ScrollPatternIdentifiers.NoScroll;

    public double HorizontalViewSize => 100;

    public bool VerticallyScrollable => _canvas.CanScroll;

    public double VerticalScrollPercent => _canvas.CanScroll ? _canvas.ScrollFraction * 100 : ScrollPatternIdentifiers.NoScroll;

    public double VerticalViewSize => _canvas.CanScroll ? _canvas.ViewFraction * 100 : 100;

    public void Scroll(ScrollAmount horizontalAmount, ScrollAmount verticalAmount)
    {
        if (horizontalAmount != ScrollAmount.NoAmount)
            throw new InvalidOperationException("The graph does not scroll horizontally.");

        switch (verticalAmount)
        {
            case ScrollAmount.LargeDecrement:
                _canvas.ScrollByPage(-1);
                break;
            case ScrollAmount.LargeIncrement:
                _canvas.ScrollByPage(1);
                break;
            case ScrollAmount.SmallDecrement:
                _canvas.ScrollByPixels(-_canvas.RowHeight);
                break;
            case ScrollAmount.SmallIncrement:
                _canvas.ScrollByPixels(_canvas.RowHeight);
                break;
        }
    }

    /// <summary>Sets the vertical position in percent (0 = the top, 100 = exactly the last row at the bottom).</summary>
    public void SetScrollPercent(double horizontalPercent, double verticalPercent)
    {
        if (horizontalPercent != ScrollPatternIdentifiers.NoScroll)
            throw new InvalidOperationException("The graph does not scroll horizontally.");
        if (verticalPercent == ScrollPatternIdentifiers.NoScroll)
            return;
        if (verticalPercent is not (>= 0 and <= 100))
            throw new ArgumentOutOfRangeException(nameof(verticalPercent), verticalPercent, "must be 0 to 100");

        if (verticalPercent >= 100)
            _canvas.ScrollToEnd();
        else
            _canvas.ScrollToFraction(verticalPercent / 100);
    }

    protected override object GetPatternCore(PatternInterface patternInterface) =>
        patternInterface == PatternInterface.Scroll ? this : base.GetPatternCore(patternInterface);

    protected override IList<AutomationPeer> GetChildrenCore()
    {
#if HISTQ_QA
        _canvas.QaAutomationEventsCount++;
        if (_canvas.QaNoAutomation)
            return [];
#endif
        long first = _canvas.FirstVisibleRow;
        long last = _canvas.LastVisibleRow;

        foreach (long row in _rowPeers.Keys)
        {
            if (row < first || row > last)
                _gone.Add(row);
        }
        foreach (long row in _gone)
            _rowPeers.Remove(row);
        _gone.Clear();

        var children = new List<AutomationPeer>();
        if (first < 0)
            return children;
        for (long row = first; row <= last; row++)
        {
            if (!_rowPeers.TryGetValue(row, out GraphRowAutomationPeer? peer))
            {
                peer = new GraphRowAutomationPeer(this, _canvas, row);
#if HISTQ_QA
                _canvas.QaAutomationRowPeersCreated++;
#endif
                _rowPeers[row] = peer;
            }
            children.Add(peer);
        }
        return children;
    }
}

/// <summary>
/// One visible graph row in UI Automation: a ListItem named after its subject, with the SelectionItem pattern (the
/// selected row) and its bounds on screen.
/// </summary>
internal sealed partial class GraphRowAutomationPeer : AutomationPeer, ISelectionItemProvider
{
    private readonly GraphAutomationPeer _list;
    private readonly GraphCanvas _canvas;

    public GraphRowAutomationPeer(GraphAutomationPeer list, GraphCanvas canvas, long row)
    {
        _list = list;
        _canvas = canvas;
        Row = row;
        SetParent(list);
    }

    /// <summary>The row index in the log, 0 = the top row.</summary>
    public long Row { get; }

    public bool IsSelected => _canvas.SelectedRow == Row;

    public IRawElementProviderSimple SelectionContainer => ProviderFromPeer(_list);

    public void AddToSelection() => Select();

    public void RemoveFromSelection()
    {
        if (IsSelected)
            _canvas.Select(-1);
    }

    public void Select()
    {
        if (Row < _canvas.RowCount)
            _canvas.Select(Row);
    }

    protected override object GetPatternCore(PatternInterface patternInterface) =>
        patternInterface == PatternInterface.SelectionItem ? this : base.GetPatternCore(patternInterface);

    protected override string GetNameCore() => _canvas.SubjectOf(Row);

    protected override string GetAutomationIdCore() => "GraphRow" + Row.ToString(CultureInfo.InvariantCulture);

    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.ListItem;

    protected override string GetClassNameCore() => "GraphRow";

    protected override bool IsControlElementCore() => true;

    protected override bool IsContentElementCore() => true;

    protected override bool IsKeyboardFocusableCore() => false;

    protected override bool IsOffscreenCore() =>
        Row < _canvas.FirstVisibleRow || Row > _canvas.LastVisibleRow;

    protected override int GetPositionInSetCore() => (int)Math.Min(int.MaxValue, Row + 1);

    protected override int GetSizeOfSetCore() => (int)Math.Min(int.MaxValue, _canvas.RowCount);

    /// <summary>
    /// The row's part of the list's bounds: the list's rectangle is in the units UI Automation wants, so the row's
    /// offset is scaled by the list's width over the canvas's.
    /// </summary>
    protected override Rect GetBoundingRectangleCore()
    {
        Rect list = _list.GetBoundingRectangle();
        if (_canvas.ActualWidth <= 0 || list.Width <= 0)
            return default;

        double scale = list.Width / _canvas.ActualWidth;
        double top = Math.Max(0, _canvas.TopOfRow(Row));
        double bottom = Math.Min(_canvas.ViewportHeight, _canvas.TopOfRow(Row) + _canvas.RowHeight);
        if (bottom <= top)
            return default;
        return new Rect(list.X, list.Y + top * scale, _canvas.ViewportWidth * scale, (bottom - top) * scale);
    }
}
