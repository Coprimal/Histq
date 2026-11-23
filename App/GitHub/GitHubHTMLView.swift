// GitHub's sanitized HTML (`body_html`) in a WKWebView, locked down like a read-only page: no JavaScript from the page
// (`allowsContentJavaScript` false), a non-persistent data store (no cookies, no cache on disk), no base URL (the page
// is `about:blank`, so nothing resolves to a file:// URL), and a Content-Security-Policy that allows no remote load at
// all: images, styles, fonts, frames and media stay blocked (a GitHub image shows as its alt text). WKWebView loads
// through its own network stack, outside the stub `URLSession`, so allowing GitHub's image CDN would let a stub run
// reach the network; showing images is a follow-up. A click on an http(s) link opens the default browser; every other
// navigation (other schemes, forms, refreshes, frames, fragment jumps) is cancelled. Colors come from `Palette`.
import AppKit
import SwiftUI
import WebKit

/// A page of GitHub HTML for a scroll view: its frame is always the content's height, the page never scrolls itself
/// (no overflow, code blocks wrap; only a table too wide for it scrolls sideways, inside it), and its vertical wheel
/// events scroll the enclosing scroll view. `html` goes into
/// the page's body: GitHub's `body_html` as GitHub sanitized it, and markup Histq built around it with every other
/// value passed through `HostedHTML.escape`.
struct HostedHTMLView: View {
    /// Starts a web view with a blank page, for the next new page to take (a pull request's while it loads).
    static func warmUp() { GitHubHTMLPage.warmUp() }

    let html: String
    /// A new value measures the page again without a load or a width change (a quiet reload of the same page).
    var measureKey = 0
    /// What the app changed on the page since it was built; a new value is applied and the page measured again,
    /// without a load.
    var patch = HostedHTMLPatch()
    /// Called once per page, when it is laid out (the timing log's content line).
    var onLoad: @MainActor () -> Void = {}
    /// Called with the page's `data-slot` elements after every measurement, in the same update as the new height, so
    /// native views drawn on them never lag the page's frame.
    var onSlots: @MainActor ([HostedHTMLSlot]) -> Void = { _ in }
    /// The body's height at the current width; nil until the first page is measured.
    @State private var contentHeight: CGFloat?

    /// The frame before the first measurement.
    private static let minimumHeight: CGFloat = 40

    var body: some View {
        GitHubHTMLPage(html: html, measureKey: measureKey, patch: patch, onLoad: onLoad) {
            contentHeight = $0
            onSlots($1)
        }
        .frame(height: contentHeight ?? Self.minimumHeight)
    }
}

/// An empty element of the page (`data-slot="<id>"`, outside GitHub's bodies, with an id of the timeline's formats)
/// that a native view covers: its frame in points from the page's top left (a CSS pixel is a point: the page is never
/// zoomed).
struct HostedHTMLSlot: Equatable, Sendable {
    let id: String
    let frame: CGRect

    /// One of the measuring script's `{id, x, y, w, h}`.
    init?(measured slot: [String: Any]) {
        guard let id = slot["id"] as? String, let x = slot["x"] as? NSNumber, let y = slot["y"] as? NSNumber,
              let width = slot["w"] as? NSNumber, let height = slot["h"] as? NSNumber
        else { return nil }
        self.id = id
        frame = CGRect(x: x.doubleValue, y: y.doubleValue, width: width.doubleValue, height: height.doubleValue)
    }
}

/// What the app changed on a loaded page without loading it again: a slot's height, when its native view is taller
/// or shorter than the stylesheet's (a reply field grown to more lines), whether an element has the `collapsed`
/// class (a review thread the user expanded or collapsed), and which comments are being edited in place. Applied
/// before every measurement, so a new page (a quiet reload) gets it too. Ids are the page's own (`data-slot`, `id`),
/// of the timeline's formats only (a slot's, `thread-<n>`, a general thread's `gthread-<n>`): nothing inside GitHub's
/// HTML (`.body`) changes, only the stylesheet hides a body while its comment is edited.
struct HostedHTMLPatch: Equatable {
    /// Heights in points, by slot id; a slot without one keeps the stylesheet's.
    var slotHeights: [String: CGFloat] = [:]
    /// Whether each element, by its `id`, has the `collapsed` class; one without an entry keeps its markup's.
    var collapsed: [String: Bool] = [:]
    /// The editor slots shown open (`cedit-<key>`, the `open` class), each with its comment's rendered body (the
    /// `.body` right before it) hidden; every other editor slot is hidden.
    var editing: Set<String> = []
}

extension View {
    /// DEBUG: keeps where this native view on slot `id` is drawn, for the slot and scroll probes
    /// (`GitHubHTMLProbe.overlayFrames`). Nothing without those probes, and nothing in Release.
    @ViewBuilder func slotProbeFrame(_ id: String) -> some View {
        #if DEBUG
        if GitHubHTMLProbe.recordsOverlays {
            onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                GitHubHTMLProbe.overlayFrames[id] = $0
            }
        } else {
            self
        }
        #else
        self
        #endif
    }
}

/// The web view behind `HostedHTMLView`: loads the page and reports the body's height and the slots after each load,
/// width change, new `measureKey` and new patch.
private struct GitHubHTMLPage: NSViewRepresentable {
    let html: String
    let measureKey: Int
    let patch: HostedHTMLPatch
    let onLoad: @MainActor () -> Void
    let onMeasure: @MainActor (CGFloat, [HostedHTMLSlot]) -> Void
    @Environment(\.tabIsShown) private var tabIsShown

    /// One store for every page: non-persistent (no cookies, no cache on disk), and one session for all of them
    /// instead of one per page. Each page still starts its own web content process (measured: 41 pages, 41
    /// processes), and there is no process pool to share: `WKProcessPool` has had no effect since macOS 12.
    private static let dataStore = WKWebsiteDataStore.nonPersistent()
    /// The last 2 loaded pages that left the screen, newest last, each with its coordinator (still its delegate, so a
    /// parked page stays locked down): the same page shown again (a pull request opened again) takes its view back
    /// instead of starting a new web content process and loading again. Memory only.
    private static var parked: [(view: MeasuredWebView, coordinator: Coordinator)] = []
    /// A blank page started while a pull request loads (`HostedHTMLView.warmUp`), with its own coordinator as its
    /// delegate: the next new page takes it once its load finished, so its web content process runs already.
    private static var warm: (view: MeasuredWebView, coordinator: Coordinator)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Starts the warm view, unless one is there.
    static func warmUp() {
        guard warm == nil else { return }
        let coordinator = Coordinator()
        let view = newView()
        view.navigationDelegate = coordinator
        view.uiDelegate = coordinator
        coordinator.expectedLoads += 1
        view.loadHTMLString(HostedHTML.document(body: ""), baseURL: nil)
        warm = (view, coordinator)
    }

    func makeNSView(context: Context) -> MeasuredWebView {
        let view: MeasuredWebView
        if let index = Self.parked.lastIndex(where: { $0.view.parkedHTML == html }) {
            view = Self.parked.remove(at: index).view
        } else if let warm = Self.warm, warm.coordinator.isLoaded {
            Self.warm = nil
            view = warm.view
        } else {
            view = Self.newView()
        }
        view.isHidden = !tabIsShown
        context.coordinator.isShown = tabIsShown
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.onWidthChange = { [weak coordinator = context.coordinator, weak view] in
            guard let coordinator, let view else { return }
            coordinator.remeasure(view)
        }
        return view
    }

    /// A new web view, locked down, hidden until its first page is laid out.
    private static func newView() -> MeasuredWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.dataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = MeasuredWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = false
        view.allowsMagnification = false
        view.allowsLinkPreview = false
        view.underPageBackgroundColor = HostedHTML.background
        // Hidden until the first page is laid out: no white frame before the dark stylesheet applies.
        view.alphaValue = 0
        #if DEBUG
        GitHubHTMLProbe.paintWhenOccluded(view)
        #endif
        return view
    }

    func updateNSView(_ view: MeasuredWebView, context: Context) {
        if view.isHidden == tabIsShown { view.isHidden = !tabIsShown }
        context.coordinator.isShown = tabIsShown
        context.coordinator.onLoad = onLoad
        context.coordinator.onMeasure = onMeasure
        let changed = context.coordinator.measureKey != measureKey || context.coordinator.patch != patch
        context.coordinator.measureKey = measureKey
        context.coordinator.patch = patch
        guard context.coordinator.loadedHTML != html else {
            // A page shown again is measured once if it skipped a measurement while hidden.
            if changed || context.coordinator.skippedMeasure { context.coordinator.remeasure(view) }
            return
        }
        context.coordinator.loadedHTML = html
        if view.parkedHTML == html {
            // A parked page taken back: loaded already, so it is measured and shown as after its load.
            view.parkedHTML = nil
            context.coordinator.webView(view, didFinish: nil)
            return
        }
        context.coordinator.expectedLoads += 1
        context.coordinator.isLoaded = false
        view.loadHTMLString(HostedHTML.document(body: html), baseURL: nil)
    }

    static func dismantleNSView(_ view: MeasuredWebView, coordinator: Coordinator) {
        view.onWidthChange = nil
        if coordinator.isLoaded, let html = coordinator.loadedHTML {
            coordinator.onLoad = {}
            coordinator.onMeasure = { _, _ in }
            view.parkedHTML = html
            parked.append((view, coordinator))
            if parked.count > 2 { parked.removeFirst() }
            return
        }
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }

    /// Tells when its width changes: the text reflows, so the page's height must be measured again. Height changes
    /// are not reported, since they follow the measurement itself.
    final class MeasuredWebView: WKWebView {
        var onWidthChange: (@MainActor () -> Void)?
        /// The loaded page's html while the view is parked (`GitHubHTMLPage.parked`).
        var parkedHTML: String?

        override func setFrameSize(_ newSize: NSSize) {
            let oldWidth = frame.width
            super.setFrameSize(newSize)
            if newSize.width != oldWidth { onWidthChange?() }
        }

        /// The page never scrolls, so a mostly-vertical wheel event scrolls the enclosing scroll view instead; a
        /// mostly-horizontal one goes to the page, where only a table too wide for it scrolls sideways, on its own.
        /// An event without a delta (a gesture's start or end) goes to the scroll view too, with the rest of its
        /// gesture.
        override func scrollWheel(with event: NSEvent) {
            guard abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX), let outer = enclosingScrollView
            else { return super.scrollWheel(with: event) }
            outer.scrollWheel(with: event)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loadedHTML: String?
        /// The main-frame loads of `about:blank` the page may make: one per `loadHTMLString`, each used up by its
        /// policy decision. A count, not a flag: a new page can come before the last one's decision (a page swapped
        /// in, or a reload, while the web content process still starts), and WebKit still asks for each superseded
        /// load first, so a flag was used up by a stale load and the newest one was cancelled (a blank page).
        var expectedLoads = 0
        /// The current page has finished loading, so it can be measured.
        var isLoaded = false
        var onLoad: @MainActor () -> Void = {}
        var onMeasure: @MainActor (CGFloat, [HostedHTMLSlot]) -> Void = { _, _ in }
        /// The view's last `measureKey`.
        var measureKey: Int?
        /// The view's last patch, applied by every measurement.
        var patch = HostedHTMLPatch()
        /// The tab shows (`tabIsShown`): a page of a kept-alive tab that is not shown skips `remeasure`
        /// (`skippedMeasure`) and is measured once when it shows again.
        var isShown = true
        /// A `remeasure` skipped while the tab was not shown.
        private(set) var skippedMeasure = false
        /// A measurement is running; `measureAgain` asks for one more after it (the width changed meanwhile).
        private var isMeasuring = false
        private var measureAgain = false

        /// First the patch (`heights`, `collapsed`, `editing`: the arguments, never text spliced into the script), then
        /// the body's border box, not `documentElement.scrollHeight`, which is never less than the view's own height
        /// and so would never let the card shrink, and every `data-slot` element's frame in the page. A slot inside
        /// GitHub's HTML (`.body`) is skipped: only Histq's own markup places native views. So is a hidden one (in a
        /// collapsed thread, a closed editor), which has no box to draw on. Only the timeline's own id formats count
        /// (`PRTimeline`: `avatar-d`, `avatar-c|i|r<n>`, `chevron-<n>`, `reply-<n>` for a slot, `thread-<n>` for
        /// `collapsed`, a general thread's `gchevron-<n>`, `greply-<n>` and `gthread-<n>`, and a comment's menu,
        /// editor, reaction row and add-reaction button, `cmenu-<g|r><n>`, `cedit-<g|r><n>`, `creact-<g|r><n>` and
        /// `cadd-<g|r><n>`, the editor open as `editing` says), in case GitHub's HTML
        /// ever left `.body` unbalanced. `width` is the page's own, for the DEBUG slot probe. Runs in the app's own content world
        /// (`.defaultClient`), apart from the page, which still has no JavaScript of its own: the page's settings and
        /// policy stay as they are.
        private static let measureScript = """
            const own = /^(avatar-d|avatar-[cir][0-9]+|g?chevron-[0-9]+|g?reply-[0-9]+|c(menu|edit|react|add)-[gr][0-9]+)$/;
            for (const slot of document.querySelectorAll('[data-slot]')) {
              if (slot.closest('.body') || !own.test(slot.dataset.slot)) continue;
              const height = heights[slot.dataset.slot];
              if (height !== undefined) slot.style.height = height + 'px';
              const id = slot.dataset.slot;
              if (id.startsWith('cedit-')) slot.classList.toggle('open', editing.includes(id));
            }
            for (const [id, on] of Object.entries(collapsed)) {
              if (!/^g?thread-[0-9]+$/.test(id)) continue;
              const element = document.getElementById(id);
              if (element && !element.closest('.body')) element.classList.toggle('collapsed', on);
            }
            const slots = [];
            for (const slot of document.querySelectorAll('[data-slot]')) {
              if (slot.closest('.body') || !own.test(slot.dataset.slot) || !slot.getClientRects().length) continue;
              const r = slot.getBoundingClientRect();
              slots.push({id: slot.dataset.slot, x: r.left + scrollX, y: r.top + scrollY, w: r.width, h: r.height});
            }
            return {height: Math.ceil(document.body.getBoundingClientRect().height), width: innerWidth, slots};
            """

        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            if action.navigationType == .linkActivated {
                GitHubLinks.open(action.request.url)
                return decisionHandler(.cancel)
            }
            let isOwnLoad = expectedLoads > 0 && action.navigationType == .other
                && action.targetFrame?.isMainFrame == true && action.request.url?.absoluteString == "about:blank"
            if isOwnLoad { expectedLoads -= 1 }
            decisionHandler(isOwnLoad ? .allow : .cancel)
        }

        /// Shown and logged once the first height is known, so the card grows before the text appears. A view
        /// without a width yet (laid out later) would measure every word on its own line: it shows at once and is
        /// measured on its first width change.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            // The warm view's blank page: nothing to show or measure.
            guard loadedHTML != nil else { return }
            let reveal: @MainActor () -> Void = { [onLoad] in
                webView.alphaValue = 1
                onLoad()
                #if DEBUG
                GitHubHTMLProbe.run(webView)
                GitHubHTMLProbe.scroll(webView)
                #endif
            }
            guard webView.frame.width > 0 else { return reveal() }
            measure(webView, then: reveal)
        }

        /// After a width change, a new `measureKey` or a new patch; nothing before the page is loaded (its load
        /// measures it, with the patch). While its tab is not shown, it waits until the tab shows again.
        func remeasure(_ webView: WKWebView) {
            guard isLoaded, webView.frame.width > 0 else { return }
            guard isShown else { return skippedMeasure = true }
            measure(webView)
        }

        private func measure(_ webView: WKWebView, then completion: (@MainActor () -> Void)? = nil) {
            skippedMeasure = false
            guard !isMeasuring else {
                measureAgain = true
                completion?()
                return
            }
            isMeasuring = true
            // Every name the script reads, always: a missing one throws, and the page is never measured.
            let arguments: [String: Any] = ["heights": patch.slotHeights.mapValues(Double.init),
                                            "collapsed": patch.collapsed, "editing": patch.editing.sorted()]
            webView.callAsyncJavaScript(
                Self.measureScript, arguments: arguments, in: nil, in: .defaultClient
            ) { [weak self] result in
                // A page still at no width (a parked page taken back: SwiftUI sizes its view to zero first) has every
                // word on its own line: it is measured again instead.
                let noWidth = ((try? result.get()) as? [String: Any])?["width"] as? NSNumber == 0
                if !noWidth, case .success(let value) = result, let page = value as? [String: Any],
                   let height = (page["height"] as? NSNumber)?.doubleValue, height > 0 {
                    let slots = (page["slots"] as? [[String: Any]] ?? []).compactMap(HostedHTMLSlot.init(measured:))
                    self?.onMeasure(CGFloat(height), slots)
                    UITiming.content("html height \(Int(height)) at width \(Int(webView.frame.width))")
                    #if DEBUG
                    GitHubHTMLProbe.slots(webView, slots, pageWidth: (page["width"] as? NSNumber)?.doubleValue ?? 0)
                    #endif
                }
                completion?()
                guard let self else { return }
                isMeasuring = false
                if measureAgain || noWidth {
                    measureAgain = false
                    remeasure(webView)
                }
            }
        }

        /// A parked or warm page whose web content process ended would come back blank: it is dropped, and one on
        /// screen is no longer loaded, so it is not parked when it leaves.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            isLoaded = false
            GitHubHTMLPage.parked.removeAll { $0.view === webView }
            if GitHubHTMLPage.warm?.view === webView { GitHubHTMLPage.warm = nil }
        }

        /// `target="_blank"` links: the link click already went to the browser; no window is ever made.
        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for action: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }
    }
}

/// Opens GitHub links in the default browser: http and https only, never another scheme a page could name.
enum GitHubLinks {
    static func open(_ url: URL?) {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return }
        NSWorkspace.shared.open(url)
    }

    static func open(_ string: String?) {
        open(string.flatMap(URL.init(string:)))
    }
}

/// The page around GitHub's HTML: the policy, the stylesheet from `Palette`, and the escaping of Histq's own values.
enum HostedHTML {
    /// Escapes text for an HTML text node or a quoted attribute value.
    nonisolated static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }

    /// The card's fill: the page is drawn on it.
    static var background: NSColor { Palette.sheetCardOpaque }

    /// `body` in a full document whose first element is the policy, before anything the body could add.
    static func document(body: String) -> String {
        """
        <!DOCTYPE html><html><head>\
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">\
        <meta charset="utf-8"><style>\(stylesheet)\(probeStylesheet)</style></head>\
        <body>\(body)</body></html>
        """
    }

    #if DEBUG
    /// DEBUG `-HistqSlotProbe`: every slot outlined, so a shot shows whether its native view covers it.
    private static let probeStylesheet = GitHubHTMLProbe.slotsEnabled ? "[data-slot] { outline: 1px solid red; }" : ""
    #else
    private static let probeStylesheet = ""
    #endif

    /// Built once, from the dark appearance's values of the palette and the system's semantic colors.
    private static let stylesheet: String = {
        var css = ""
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            let text = rgba(Palette.diffText)
            let secondary = rgba(.secondaryLabelColor)
            let border = rgba(NSColor(Palette.surfaceBorder))
            let header = rgba(NSColor(Palette.tabFill))
            let code = rgba(NSColor(Palette.inputSurface))
            let link = rgba(NSColor(Color.accentColor))
            let added = rgba(Palette.diffAddedSign)
            let removed = rgba(Palette.diffRemovedSign)
            let addedFill = rgba(Palette.diffAddedFill)
            let removedFill = rgba(Palette.diffRemovedFill)
            let number = rgba(Palette.diffLineNumber)
            let outdated = rgba(NSColor(Palette.conflictTone))
            let mono = "ui-monospace, \"SF Mono\", Menlo, monospace"
            css = """
                html, body { margin: 0; padding: 0; overflow: hidden; background: \(rgba(background)); color: \(text);
                  font: 13px/1.5 -apple-system, system-ui, sans-serif; -webkit-font-smoothing: antialiased; }
                body { padding: 2px 0 10px; overflow-wrap: anywhere; }
                a { color: \(link); text-decoration: none; } a:hover { text-decoration: underline; }
                p, ul, ol, pre, blockquote, table { margin: 0 0 8px; } .body > :last-child { margin-bottom: 0; }
                h1, h2, h3, h4 { margin: 12px 0 6px; line-height: 1.25; } h1 { font-size: 1.4em; } h2 { font-size: 1.25em; }
                code, pre { font: 12px ui-monospace, "SF Mono", Menlo, monospace; background: \(code); border-radius: 6px; }
                code { padding: 1px 4px; } pre { padding: 8px 10px; white-space: pre-wrap; }
                pre code { padding: 0; background: none; }
                blockquote { margin-left: 0; padding-left: 10px; border-left: 3px solid \(border); color: \(secondary); }
                table { border-collapse: collapse; } td, th { border: 1px solid \(border); padding: 4px 8px; }
                .body table { display: block; overflow-x: auto; } .body td, .body th { overflow-wrap: break-word; }
                img { max-width: 100%; } hr { border: 0; border-top: 1px solid \(border); }
                .item { border: 1px solid \(border); border-radius: 10px; margin: 0 0 10px; overflow: hidden; }
                .head { background: \(header); padding: 6px 10px; color: \(secondary); display: flex; gap: 6px;
                  align-items: baseline; flex-wrap: wrap; }
                .head b { color: \(text); font-weight: 600; } .head .date { margin-left: auto; }
                .body { padding: 8px 10px; } .empty { color: \(secondary); font-style: italic; } .plain { white-space: pre-wrap; }
                .badge { font-weight: 600; } .approved { color: \(added); } .changes { color: \(removed); }
                .slot-avatar { flex: none; align-self: center; width: 20px; height: 20px; }
                .slot-reply { height: 44px; }
                .threads { padding: 0 10px 10px; } .threads.loose { padding: 0; }
                .thread { border: 1px solid \(border); border-radius: 8px; margin-top: 8px; overflow: hidden; }
                .loose .thread { margin: 0 0 10px; }
                .thread-head { display: flex; align-items: center; gap: 6px; padding: 5px 10px; background: \(header);
                  color: \(secondary); white-space: nowrap; }
                .thread:not(.collapsed) > .thread-head { border-bottom: 1px solid \(border); }
                .thread.collapsed > :not(.thread-head) { display: none; }
                .slot-chevron { flex: none; width: 16px; height: 16px; }
                .path { display: flex; min-width: 0; font: 12px \(mono); color: \(text); }
                .path .folder { flex-shrink: 1000; min-width: 0; overflow: hidden; text-overflow: ellipsis; }
                .path .file { min-width: 0; overflow: hidden; text-overflow: ellipsis; }
                .lines { flex: none; }
                .cap { flex: none; font-size: 11px; line-height: 16px; padding: 0 7px; border: 1px solid \(border);
                  border-radius: 9px; } .cap.outdated { color: \(outdated); }
                .cap.resolved { color: \(added); border-color: \(added); background: \(addedFill); font-weight: 600; }
                .excerpt { width: 100%; margin: 0; border-collapse: collapse; font: 12px/18px \(mono); }
                .excerpt td { border: 0; padding: 0; vertical-align: top; }
                .excerpt .num { width: 1px; padding: 0 8px; text-align: right; color: \(number); font-size: 11px;
                  white-space: nowrap; user-select: none; }
                .excerpt .sign { width: 14px; text-align: center; user-select: none; }
                .excerpt .code { padding-right: 10px; white-space: pre-wrap; tab-size: 4; }
                .excerpt .add td { background: \(addedFill); } .excerpt .add .sign { color: \(added); }
                .excerpt .del td { background: \(removedFill); } .excerpt .del .sign { color: \(removed); }
                .comment { padding: 8px 10px; border-top: 1px solid \(border); }
                .excerpt + .comment, .thread-head + .comment { border-top: 0; }
                .comment-head { display: flex; gap: 6px; align-items: baseline; color: \(secondary); }
                .comment-head b { color: \(text); font-weight: 600; } .comment-head .date { margin-left: auto; }
                .comment > .body { padding: 4px 0 0 26px; }
                .thread .slot-reply, .item > .slot-reply { margin: 0 10px 8px 36px; }
                .item.collapsed > :not(.head) { display: none; } .head .slot-chevron { align-self: center; }
                .slot-menu, .slot-add { flex: none; align-self: center; width: 18px; height: 18px; }
                .slot-edit { display: none; } .slot-edit.open { display: block; height: 120px; }
                .item > .slot-edit { margin: 0 10px; } .comment > .slot-edit { margin: 0 0 0 26px; }
                .body:has(+ .slot-edit.open) { display: none; }
                .slot-react { height: 22px; } .item > .slot-react { margin: 0 10px 8px; }
                .comment > .slot-react { margin: 6px 0 0 26px; }
                .replies { margin: 0 10px 8px 19px; border-left: 2px solid \(border); }
                .replies .replies { margin: 0 0 0 21px; } .thread > .replies { margin: 0 0 0 19px; }
                .replies > .comment { border-top: 0; padding: 4px 10px 6px 12px; }
                .handle { color: \(secondary); font-weight: 400; }
                .gl .head .date, .gl .comment-head .date { margin-left: 0; }
                .gl .date + .slot-add, .gl .date + .slot-menu { margin-left: auto; }
                .resolved-line { background: \(header); color: \(secondary); font-size: 12px; padding: 0 10px 6px 36px; }
                .resolved-line b { color: \(text); font-weight: 600; }
                .snippet { padding: 8px 10px 0; } .snippet .thread { margin-top: 0; }
                .fold { border-top: 1px solid \(border); }
                .summary { position: relative; display: flex; align-items: center; gap: 6px; padding: 6px 10px 6px 34px;
                  color: \(secondary); }
                .summary > .slot-chevron { position: absolute; left: 0; top: 0; right: 0; bottom: 0; width: auto;
                  height: auto; }
                .summary b { color: \(text); font-weight: 600; } .summary .count { color: \(link); }
                .folded { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; }
                .fold.collapsed > .replies, .fold.collapsed > .slot-reply, .fold.collapsed .open,
                .fold:not(.collapsed) .folded { display: none; }
                .fold > .replies { margin-top: 4px; } .fold > .slot-reply, .item.gl > .slot-reply { margin: 0 10px 8px 36px; }
                .rail { margin-left: 10px; padding-left: 14px; border-left: 2px solid \(border); }
                .event { position: relative; margin: 0 0 10px; padding: 2px 0; color: \(secondary); }
                .event .dot { position: absolute; left: -20px; top: 8px; width: 8px; height: 8px; border-radius: 50%;
                  background: \(secondary); box-shadow: 0 0 0 3px \(rgba(background)); }
                .event b { color: \(text); font-weight: 600; }
                .event .body { display: inline; padding: 0; } .event .body > p { display: inline; margin: 0; }
                .event .date { margin-left: 4px; }
                """
        }
        return css
    }()

    /// `rgba(r, g, b, a)` of a color in sRGB.
    private static func rgba(_ color: NSColor) -> String {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        func byte(_ value: CGFloat) -> Int { Int((max(0, min(1, value)) * 255).rounded()) }
        return "rgba(\(byte(srgb.redComponent)), \(byte(srgb.greenComponent)), \(byte(srgb.blueComponent)), "
            + String(format: "%.3f", srgb.alphaComponent) + ")"
    }
}

#if DEBUG
/// DEBUG probe of a QA run (state dir set and `-HistqHTMLProbe YES`): what the page really drew, apart from what a
/// window capture shows. Only on that flag: counting the ink walks every pixel on the main thread. Half a second after
/// the page shows, `takeSnapshot` renders it in the web process, whether the window is visible or not;
/// the PNG goes to `<stateDir>/html-<n>.png` and the timing log gets `html <n> snapshot <w>x<h> ink <pixels>`
/// (pixels that differ from the page background), the view's frame and whether AppKit reports the window visible.
enum GitHubHTMLProbe {
    @MainActor private static var count = 0

    /// A background QA launch orders its window behind the others, so AppKit reports it occluded and WebKit never
    /// paints the page into the window (the capture shows the view's empty background). WebKit's private occlusion
    /// switch makes it paint as in a visible window; DEBUG background launches only, never in Release.
    @MainActor static func paintWhenOccluded(_ view: WKWebView) {
        guard AppState.isBackgroundLaunch else { return }
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        let responds = view.responds(to: selector)
        if responds {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(view.method(for: selector), to: Setter.self)(view, selector, false)
        }
        UITiming.content("html occlusion-detection-off \(responds)")
    }

    @MainActor static func run(_ view: WKWebView) {
        guard let directory = AppState.stateDirectory, AppState.launchFlag("-HistqHTMLProbe") == "YES" else { return }
        count += 1
        let index = count
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let visible = view.window?.occlusionState.contains(.visible) ?? false
            let size = "\(Int(view.frame.width))x\(Int(view.frame.height))"
            UITiming.content("html \(index) frame \(size) window-visible \(visible)")
            view.takeSnapshot(with: nil) { image, error in
                guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
                    return UITiming.content("html \(index) snapshot failed \(error.map { "\($0)" } ?? "")")
                }
                let ink = inkPixels(bitmap)
                try? bitmap.representation(using: .png, properties: [:])?
                    .write(to: directory.appending(path: "html-\(index).png"))
                UITiming.content("html \(index) snapshot \(bitmap.pixelsWide)x\(bitmap.pixelsHigh) ink \(ink)")
            }
        }
    }

    @MainActor private static var didScroll = false

    /// DEBUG `-HistqScrollProbe YES`, stub runs only: half a second after the first page shows (its measured
    /// height is laid out by then), a synthetic wheel event of 120 px down goes to that page, and the timing log gets
    /// `scroll-probe outer <before>-><after>`: the enclosing scroll view's offset before the event and half a second
    /// after it. Before it, `scroll-probe document <h> clip <h>` (whether there is room to scroll) and `scroll-probe
    /// hit <class> page <bool>` (whether a real wheel event at the page's visible center would reach the page). Then
    /// the same wheel over native overlays (`wheelOverOverlays`). Not with `-HistqHTMLProbe`: its pixel count blocks
    /// the main thread for seconds, and the line then reads `0->0`.
    @MainActor static func scroll(_ view: WKWebView) {
        guard !didScroll, GitHubStub.isEnabled, AppState.launchFlag("-HistqScrollProbe") == "YES" else { return }
        didScroll = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let outer = view.enclosingScrollView else { return UITiming.probe("scroll-probe", "outer none") }
            let document = outer.documentView?.frame.height ?? 0
            UITiming.probe("scroll-probe", "document \(Int(document)) clip \(Int(outer.contentView.bounds.height))")
            // The window's frame view has no superview: its hit test takes window coordinates.
            let visible = view.visibleRect
            let center = view.convert(NSPoint(x: visible.midX, y: visible.midY), to: nil)
            let hit = view.window?.contentView?.superview?.hitTest(center)
            let onPage = hit.map { $0 === view || $0.isDescendant(of: view) } ?? false
            UITiming.probe("scroll-probe", "hit \(hit.map { "\(type(of: $0))" } ?? "none") page \(onPage)")
            let before = outer.contentView.bounds.minY
            guard let wheel = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -120, wheel2: 0, wheel3: 0),
                let event = NSEvent(cgEvent: wheel)
            else { return UITiming.probe("scroll-probe", "outer no-event") }
            view.scrollWheel(with: event)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                UITiming.probe("scroll-probe", "outer \(Int(before))->\(Int(outer.contentView.bounds.minY))")
                wheelOverOverlays(view, outer)
            }
        }
    }

    /// The page's wheel again, over overlays this time: the topmost avatar in view (downward), then the reply row when
    /// the page has one, with the column first scrolled to bring it to the middle of the view and the wheel going up.
    /// Each goes to the view a real event at the overlay's center would hit: `scroll-probe overlay <id> hit <class>
    /// page <bool> outer <before>-><after>`. Last, the column is scrolled to its end (the merge and comment boxes under
    /// the page), for the run's shot.
    @MainActor private static func wheelOverOverlays(_ view: WKWebView, _ outer: NSScrollView) {
        guard let root = view.window?.contentView else { return }
        let clip = outer.contentView.convert(outer.contentView.bounds, to: root)
        let avatar = overlayFrames.filter { $0.key.hasPrefix("avatar") && clip.contains(CGPoint(x: $0.value.midX,
                                                                                                y: $0.value.midY)) }
            .min { $0.value.minY < $1.value.minY }?.key
        wheel(over: avatar ?? "avatar (none in view)", delta: -120, view, outer) {
            // A page without review threads (an issue) has no reply row: straight to the column's end.
            guard let reply = overlayFrames.keys.filter({ $0.hasPrefix("reply-") }).min(),
                  let frame = overlayFrames[reply]
            else { return scrollColumn(outer, to: .infinity) }
            let clip = outer.contentView.convert(outer.contentView.bounds, to: root)
            scrollColumn(outer, to: outer.contentView.bounds.minY + frame.midY - clip.midY)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                wheel(over: reply, delta: 120, view, outer) {
                    scrollColumn(outer, to: .infinity)
                }
            }
        }
    }

    /// Scrolls `outer` to `offset` from its top, kept within its content.
    @MainActor private static func scrollColumn(_ outer: NSScrollView, to offset: CGFloat) {
        let end = max(0, (outer.documentView?.frame.height ?? 0) - outer.contentView.bounds.height)
        outer.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, offset), end)))
        outer.reflectScrolledClipView(outer.contentView)
    }

    @MainActor private static func wheel(
        over id: String, delta: Int32, _ view: WKWebView, _ outer: NSScrollView,
        then next: @escaping @MainActor () -> Void
    ) {
        guard let frame = overlayFrames[id], let root = view.window?.contentView,
              let hit = root.superview?.hitTest(root.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)),
              let wheel = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0),
              let event = NSEvent(cgEvent: wheel)
        else { return UITiming.probe("scroll-probe", "overlay \(id) none") }
        let onPage = hit === view || hit.isDescendant(of: view)
        let before = outer.contentView.bounds.minY
        hit.scrollWheel(with: event)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let after = outer.contentView.bounds.minY
            UITiming.probe("scroll-probe",
                           "overlay \(id) hit \(type(of: hit)) page \(onPage) outer \(Int(before))->\(Int(after))")
            next()
        }
    }

    /// DEBUG `-HistqSlotProbe YES`, stub runs only: whether each native view sits on its slot. Half a second after
    /// each measurement, the timing log gets `slot-probe pass <n> <load|width|remeasure> view <w>x<h> page-width <w>
    /// slots <k> overlays <m>`, then for each slot `slot-probe <id> html <x,y,w,h> overlay <x,y,w,h> delta <d>`: the
    /// slot's frame from the page, and where SwiftUI drew its overlay, taken into the web view's own AppKit frame (a
    /// web view that sits elsewhere than SwiftUI thinks shows as a delta); `delta` is the largest difference. Three
    /// seconds after the first measurement the window grows by 400 pt, 200 on each side, for a pass at another width.
    /// Slots are outlined in red (`HostedHTML.probeStylesheet`).
    static let slotsEnabled = GitHubStub.isEnabled && AppState.launchFlag("-HistqSlotProbe") == "YES"
    /// The overlays' frames are kept for the slot probe and for the scroll probe's wheel over an overlay.
    static let recordsOverlays = slotsEnabled
        || GitHubStub.isEnabled && AppState.launchFlag("-HistqScrollProbe") == "YES"
    /// Each overlay's frame in SwiftUI's global space (the window's hosting view), by slot id (`slotProbeFrame`).
    @MainActor static var overlayFrames: [String: CGRect] = [:]
    @MainActor private static var slotPasses = 0
    @MainActor private static var slotWidth: CGFloat?
    /// The last measurement's slots and page width: a pass logs the page as it is by then.
    @MainActor private static var lastSlots: (slots: [HostedHTMLSlot], pageWidth: Double) = ([], 0)
    @MainActor private static var didResize = false

    @MainActor static func slots(_ view: WKWebView, _ slots: [HostedHTMLSlot], pageWidth: Double) {
        // A slot gone from the page (the reply row of a thread just collapsed) takes its overlay's frame with it: the
        // scroll probe picks the overlays it wheels over from these.
        if recordsOverlays {
            let ids = Set(slots.map(\.id))
            overlayFrames = overlayFrames.filter { ids.contains($0.key) }
        }
        guard slotsEnabled else { return }
        let reason = slotWidth == nil ? "load" : slotWidth == view.frame.width ? "remeasure" : "width"
        slotWidth = view.frame.width
        lastSlots = (slots, pageWidth)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            logSlots(view, reason: reason)
        }
        guard !didResize, let window = view.window else { return }
        didResize = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let old = window.frame.width
            window.setFrame(window.frame.insetBy(dx: -200, dy: 0), display: true)
            UITiming.probe("slot-probe", "resize \(Int(old))->\(Int(window.frame.width))")
        }
    }

    @MainActor private static func logSlots(_ view: WKWebView, reason: String) {
        guard let root = view.window?.contentView else { return UITiming.probe("slot-probe", "no window") }
        let (slots, pageWidth) = lastSlots
        slotPasses += 1
        let page = view.convert(view.bounds, to: root)
        let origin = root.isFlipped ? page.origin : CGPoint(x: page.minX, y: root.bounds.height - page.maxY)
        let overlays = slots.count { overlayFrames[$0.id] != nil }
        let size = "\(Int(view.frame.width))x\(Int(view.frame.height))"
        UITiming.probe("slot-probe", "pass \(slotPasses) \(reason) view \(size) page-width \(Int(pageWidth))"
            + " slots \(slots.count) overlays \(overlays)")
        func text(_ rect: CGRect) -> String {
            String(format: "%.1f,%.1f,%.1f,%.1f", rect.minX, rect.minY, rect.width, rect.height)
        }
        for slot in slots {
            guard let global = overlayFrames[slot.id] else {
                UITiming.probe("slot-probe", "\(slot.id) html \(text(slot.frame)) overlay none")
                continue
            }
            let overlay = global.offsetBy(dx: -origin.x, dy: -origin.y)
            let delta = max(abs(overlay.minX - slot.frame.minX), abs(overlay.minY - slot.frame.minY),
                            abs(overlay.width - slot.frame.width), abs(overlay.height - slot.frame.height))
            UITiming.probe("slot-probe", "\(slot.id) html \(text(slot.frame)) overlay \(text(overlay))"
                + " delta \(String(format: "%.2f", delta))")
        }
    }

    /// Pixels whose color is more than a few steps away from the top-left pixel (the page background).
    private static func inkPixels(_ bitmap: NSBitmapImageRep) -> Int {
        guard let reference = bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB) else { return -1 }
        var ink = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 1) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 1) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let delta = abs(color.redComponent - reference.redComponent)
                    + abs(color.greenComponent - reference.greenComponent)
                    + abs(color.blueComponent - reference.blueComponent)
                if delta > 0.06 { ink += 1 }
            }
        }
        return ink
    }
}
#endif
