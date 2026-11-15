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

/// A page of GitHub HTML as tall as its content, at most the height it is offered, scrolling on its own past that.
/// `html` goes into the page's body: GitHub's `body_html` as GitHub sanitized it, and markup Histq built around it with
/// every other value passed through `GitHubHTML.escape`.
struct GitHubHTMLView: View {
    let html: String
    /// Called once per page, when it is laid out (the timing log's content line).
    var onLoad: @MainActor () -> Void = {}
    /// The body's height at the current width; nil until the first page is measured.
    @State private var contentHeight: CGFloat?

    /// The frame before the first measurement, and the least the page shrinks to in a short panel.
    private static let minimumHeight: CGFloat = 40

    var body: some View {
        GitHubHTMLPage(html: html, onLoad: onLoad) { contentHeight = $0 }
            .frame(minHeight: Self.minimumHeight, maxHeight: max(Self.minimumHeight, contentHeight ?? 0))
    }
}

/// The web view behind `GitHubHTMLView`: loads the page and reports the body's height after each load and width change.
private struct GitHubHTMLPage: NSViewRepresentable {
    let html: String
    let onLoad: @MainActor () -> Void
    let onHeight: @MainActor (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MeasuredWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = MeasuredWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        view.allowsMagnification = false
        view.allowsLinkPreview = false
        view.underPageBackgroundColor = GitHubHTML.background
        // Hidden until the first page is laid out: no white frame before the dark stylesheet applies.
        view.alphaValue = 0
        view.onWidthChange = { [weak coordinator = context.coordinator, weak view] in
            guard let coordinator, let view else { return }
            coordinator.widthChanged(view)
        }
        #if DEBUG
        GitHubHTMLProbe.paintWhenOccluded(view)
        #endif
        return view
    }

    func updateNSView(_ view: MeasuredWebView, context: Context) {
        context.coordinator.onLoad = onLoad
        context.coordinator.onHeight = onHeight
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        context.coordinator.expectsLoad = true
        context.coordinator.isLoaded = false
        view.loadHTMLString(GitHubHTML.document(body: html), baseURL: nil)
    }

    static func dismantleNSView(_ view: MeasuredWebView, coordinator: Coordinator) {
        view.onWidthChange = nil
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }

    /// Tells when its width changes: the text reflows, so the page's height must be measured again. Height changes
    /// are not reported, since they follow the measurement itself.
    final class MeasuredWebView: WKWebView {
        var onWidthChange: (@MainActor () -> Void)?

        override func setFrameSize(_ newSize: NSSize) {
            let oldWidth = frame.width
            super.setFrameSize(newSize)
            if newSize.width != oldWidth { onWidthChange?() }
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loadedHTML: String?
        /// Set by `loadHTMLString`: the one main-frame load of `about:blank` the page may make.
        var expectsLoad = false
        /// The current page has finished loading, so it can be measured.
        var isLoaded = false
        var onLoad: @MainActor () -> Void = {}
        var onHeight: @MainActor (CGFloat) -> Void = { _ in }
        /// A measurement is running; `measureAgain` asks for one more after it (the width changed meanwhile).
        private var isMeasuring = false
        private var measureAgain = false

        /// The body's border box, not `documentElement.scrollHeight`, which is never less than the view's own height
        /// and so would never let the card shrink. Runs in the app's own content world (`.defaultClient`), apart
        /// from the page, which still has no JavaScript of its own: the page's settings and policy stay as they are.
        private static let heightScript = "Math.ceil(document.body.getBoundingClientRect().height)"

        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            if action.navigationType == .linkActivated {
                GitHubLinks.open(action.request.url)
                return decisionHandler(.cancel)
            }
            let isOwnLoad = expectsLoad && action.navigationType == .other && action.targetFrame?.isMainFrame == true
                && action.request.url?.absoluteString == "about:blank"
            if isOwnLoad { expectsLoad = false }
            decisionHandler(isOwnLoad ? .allow : .cancel)
        }

        /// Shown and logged once the first height is known, so the card grows before the text appears. A view
        /// without a width yet (laid out later) would measure every word on its own line: it shows at once and is
        /// measured on its first width change.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            let reveal: @MainActor () -> Void = { [onLoad] in
                webView.alphaValue = 1
                onLoad()
                #if DEBUG
                GitHubHTMLProbe.run(webView)
                #endif
            }
            guard webView.frame.width > 0 else { return reveal() }
            measure(webView, then: reveal)
        }

        func widthChanged(_ webView: WKWebView) {
            guard isLoaded, webView.frame.width > 0 else { return }
            measure(webView)
        }

        private func measure(_ webView: WKWebView, then completion: (@MainActor () -> Void)? = nil) {
            guard !isMeasuring else {
                measureAgain = true
                completion?()
                return
            }
            isMeasuring = true
            webView.evaluateJavaScript(Self.heightScript, in: nil, in: .defaultClient) { [weak self] result in
                if case .success(let value) = result, let height = (value as? NSNumber)?.doubleValue, height > 0 {
                    self?.onHeight(CGFloat(height))
                    UITiming.content("html height \(Int(height)) at width \(Int(webView.frame.width))")
                }
                completion?()
                guard let self else { return }
                isMeasuring = false
                if measureAgain {
                    measureAgain = false
                    widthChanged(webView)
                }
            }
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
enum GitHubHTML {
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
        <meta charset="utf-8"><style>\(stylesheet)</style></head><body>\(body)</body></html>
        """
    }

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
            css = """
                html, body { margin: 0; padding: 0; background: \(rgba(background)); color: \(text);
                  font: 13px/1.5 -apple-system, system-ui, sans-serif; -webkit-font-smoothing: antialiased; }
                body { padding: 2px 0 10px; overflow-wrap: anywhere; }
                a { color: \(link); text-decoration: none; } a:hover { text-decoration: underline; }
                p, ul, ol, pre, blockquote, table { margin: 0 0 8px; } .body > :last-child { margin-bottom: 0; }
                h1, h2, h3, h4 { margin: 12px 0 6px; line-height: 1.25; } h1 { font-size: 1.4em; } h2 { font-size: 1.25em; }
                code, pre { font: 12px ui-monospace, "SF Mono", Menlo, monospace; background: \(code); border-radius: 6px; }
                code { padding: 1px 4px; } pre { padding: 8px 10px; overflow-x: auto; } pre code { padding: 0; background: none; }
                blockquote { margin-left: 0; padding-left: 10px; border-left: 3px solid \(border); color: \(secondary); }
                table { border-collapse: collapse; } td, th { border: 1px solid \(border); padding: 4px 8px; }
                img { max-width: 100%; } hr { border: 0; border-top: 1px solid \(border); }
                .item { border: 1px solid \(border); border-radius: 10px; margin: 0 0 10px; overflow: hidden; }
                .head { background: \(header); padding: 6px 10px; color: \(secondary); display: flex; gap: 6px;
                  align-items: baseline; flex-wrap: wrap; }
                .head b { color: \(text); font-weight: 600; } .head .date { margin-left: auto; }
                .body { padding: 8px 10px; } .empty { color: \(secondary); font-style: italic; } .plain { white-space: pre-wrap; }
                .badge { font-weight: 600; } .approved { color: \(added); } .changes { color: \(removed); }
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
