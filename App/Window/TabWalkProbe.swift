#if DEBUG
import AppKit

/// DEBUG `-HistqTabWalk "<step>,<step>,…"` (QA of the graph's view across tab switches): once the window is up, runs
/// each step 800 ms apart, then logs the graph's view to `timing.log` as `tabwalk <step> repo=<name> y=<clip origin y>
/// inset=<clip top inset> h=<clip height> top=<first row wholly below the header> sel=<selected rows>
/// shown=<yes|no: the first selected row is wholly between the header and the bottom>`. Steps:
/// - `t<n>`: a click on tab n.
/// - `y<pt>`: scrolls the graph so its clip's origin is at that y, as a scroll would.
/// - `r<n>`: a click on graph row n.
extension WindowModel {
    private static var didTabWalk = false

    func debugTabWalk() async {
        guard !Self.didTabWalk, let spec = AppState.launchFlag("-HistqTabWalk") else { return }
        Self.didTabWalk = true
        try? await Task.sleep(for: .seconds(2))
        for step in spec.split(separator: ",").map(String.init) {
            let value = Int(step.dropFirst()) ?? 0
            switch step.first {
            case "t": selectTab(at: value)
            case "y":
                if let table = graphTable, let scroll = table.enclosingScrollView {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(value)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            case "r":
                if let table = graphTable {
                    table.selectRowIndexes(IndexSet(integer: value), byExtendingSelection: false)
                }
            default: break
            }
            try? await Task.sleep(for: .milliseconds(800))
            UITiming.probe("tabwalk", "\(step) " + graphViewDescription())
        }
    }

    private var graphTable: NSTableView? { selectedSession?.graphSearch.table as? NSTableView }

    private func graphViewDescription() -> String {
        let repo = selectedSession?.url.lastPathComponent ?? "-"
        guard let table = graphTable, let clip = table.enclosingScrollView?.contentView else { return "repo=\(repo) none" }
        let bounds = clip.bounds
        let top = clip.contentInsets.top
        let visibleTop = bounds.minY + top
        let firstRow = table.row(at: NSPoint(x: 1, y: visibleTop + 0.5))
        let topRow = firstRow >= 0 && table.rect(ofRow: firstRow).minY < visibleTop - 0.5 ? firstRow + 1 : firstRow
        let selected = table.selectedRowIndexes
        let shown = selected.first.map { row in
            let rect = table.rect(ofRow: row)
            return rect.minY >= visibleTop - 0.5 && rect.maxY <= bounds.maxY - clip.contentInsets.bottom + 0.5
        } ?? false
        return "repo=\(repo) y=\(Int(bounds.minY.rounded())) inset=\(Int(top.rounded())) "
            + "h=\(Int(bounds.height.rounded())) top=\(topRow) sel=\(selected.map(String.init).joined(separator: "+")) "
            + "shown=\(shown ? "yes" : "no")"
    }
}
#endif
