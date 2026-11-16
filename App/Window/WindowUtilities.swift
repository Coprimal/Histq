// Window utilities (Dblore `WindowUtilities.swift`): the tab row's window dragging, and what joins the repo windows
// into one native window tab group.
import AppKit
import Observation
import SwiftUI

// MARK: - Window dragging

/// Behind the tab strip: a mouse-down on its empty space drags the window, like the toolbar's.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowDragView() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowDragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            // A double-click acts like one on the title bar, and starts no drag.
            if event.clickCount == 2 { return TitleBarDoubleClick.perform(on: window) }
            window.performDrag(with: event)
        }
    }
}

/// What a double-click on a window's title bar does, from System Settings › Desktop & Dock › "Double-click a
/// window's title bar to": for the tab row, which AppKit does not see as title bar.
@MainActor
enum TitleBarDoubleClick {
    static func perform(on window: NSWindow) {
        let defaults = UserDefaults.standard  // includes the global domain
        guard let action = defaults.string(forKey: "AppleActionOnDoubleClick")?.lowercased() else {
            // Never set: the older "minimize on double-click" switch, else zoom.
            return defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick") ? window.miniaturize(nil) : window.zoom(nil)
        }
        if action.contains("none") || action.contains("nothing") { return }
        if action == "minimize" { return window.miniaturize(nil) }
        if action.contains("fill"), let item = fillItem(), let fill = item.action, window.responds(to: fill),
           NSApp.sendAction(fill, to: window, from: item) { return }
        // "Maximize", an unknown value, or Fill where AppKit has no Window › Fill.
        window.zoom(nil)
    }

    /// AppKit's Window › Fill item: its action is private (e.g. `_zoomFill:`), so it is found by its action's name.
    static func fillItem() -> NSMenuItem? {
        func find(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if let action = item.action, NSStringFromSelector(action).lowercased().contains("fill") { return item }
                if let submenu = item.submenu, let found = find(submenu) { return found }
            }
            return nil
        }
        return (NSApp.windowsMenu ?? NSApp.mainMenu).flatMap(find)
    }
}

/// Under the tab strip's interactive controls: the window is not movable while the pointer is over them, so a drag
/// reaches the SwiftUI gesture (a tab's reorder) instead of moving the window. AppKit asks the hosting view, not this
/// background view, whether a mouse-down moves the window.
struct WindowDragBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowDragBlockerView() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowDragBlockerView: NSView {
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) { window?.isMovable = false }

        override func mouseExited(with event: NSEvent) { window?.isMovable = true }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            // A control removed under the pointer (a closed tab) never gets mouseExited.
            if newWindow == nil { window?.isMovable = true }
            super.viewWillMove(toWindow: newWindow)
        }

        override nonisolated func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// A middle click (the wheel's button) released on the view it backs runs `action`, as Chrome closes a tab with it.
/// SwiftUI has no gesture for that button: a local `.otherMouseUp` monitor, live while the view is in a window, takes
/// the click when it lands in the view's visible part; any other click goes on as before (the view takes no hits).
struct MiddleClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView(action: action) }

    func updateNSView(_ nsView: CatcherView, context: Context) { nsView.action = action }

    final class CatcherView: NSView {
        var action: () -> Void
        private var monitor: Any?

        init(action: @escaping () -> Void) {
            self.action = action
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { [weak self] event in
                let button = event.buttonNumber
                let eventWindow = event.window
                let point = event.locationInWindow
                let taken = MainActor.assumeIsolated {
                    guard let self, button == 2, eventWindow === self.window, !self.isHiddenOrHasHiddenAncestor
                    else { return false }
                    // Both: the visible rect alone can reach past the view's bounds (seen in the tab strip).
                    let local = self.convert(point, from: nil)
                    guard self.bounds.contains(local), self.visibleRect.contains(local) else { return false }
                    self.action()
                    return true
                }
                return taken ? nil : event
            }
        }

        override nonisolated func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

#if DEBUG
// MARK: - Double-click probe (DEBUG)

/// What a double-click on the toolbar row or the tab row does (tasks 1.1, 1.2). State-dir runs only: every
/// left mouse-down logs `click <count> hit=<view> movable=<isMovable> region=<titlebar|tabrow|content>` to
/// `timing.log`, every zoom logs `zoom to=<frame>`; `-HistqDoubleClick toolbar|tabrow` sends a synthetic click, then
/// double-click, at an empty point of that row and logs `dblclick <row> before=<frame> after=<frame>`.
@MainActor
enum DoubleClickProbe {
    private static var monitor: Any?

    static func install() {
        guard AppState.isStateDirMode, monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated {
                log(event, source: "monitor")
            }
            return event
        }
    }

    private static func log(_ event: NSEvent, source: String) {
        guard let window = event.window else {
            return UITiming.probe("click", "\(event.clickCount) hit=none movable=? region=none src=\(source)")
        }
        let point = event.locationInWindow
        let hit = hitView(in: window, at: point)
        UITiming.probe("click", "\(event.clickCount) hit=\(name(hit)) movable=\(window.isMovable) "
            + "region=\(region(of: point, in: window)) src=\(source) at=\(Int(point.x)),\(Int(point.y)) "
            + "chain=\(chain(hit)) canMove=\(hit?.mouseDownCanMoveWindow.description ?? "?")")
    }

    /// The view the window's frame view (the theme frame, `contentView.superview`) hit-tests at a window point.
    private static func hitView(in window: NSWindow, at point: NSPoint) -> NSView? {
        guard let frameView = window.contentView?.superview else { return window.contentView?.hitTest(point) }
        return frameView.hitTest(frameView.superview?.convert(point, from: nil) ?? point)
    }

    private static func region(of point: NSPoint, in window: NSWindow) -> String {
        if point.y > window.contentLayoutRect.maxY { return "titlebar" }
        if let drag = dragView(in: window), drag.convert(drag.bounds, to: nil).contains(point) { return "tabrow" }
        return "content"
    }

    /// The tab row's `WindowDragView`, found by class name (it is private to `WindowDragArea`).
    private static func dragView(in window: NSWindow) -> NSView? {
        func find(_ view: NSView) -> NSView? {
            if name(view) == "WindowDragView" { return view }
            for subview in view.subviews { if let found = find(subview) { return found } }
            return nil
        }
        return window.contentView.flatMap(find)
    }

    private static func name(_ view: NSView?) -> String { view.map { String(describing: type(of: $0)) } ?? "none" }

    /// The hit view's next six ancestors, nearest first.
    private static func chain(_ view: NSView?) -> String {
        var names: [String] = []
        var current = view?.superview
        while let ancestor = current, names.count < 6 {
            names.append(name(ancestor))
            current = ancestor.superview
        }
        return names.joined(separator: "<")
    }

    // MARK: Seam

    /// `-HistqDoubleClick <row>`: a click (count 1), then a double-click (count 2), at an empty point of the row.
    /// Each mouse-up is queued before its mouse-down is sent, so a tracking loop inside the mouse-down
    /// (`performDrag`, the title bar's own drag) finds it instead of waiting for a real one.
    /// `NSWindow.sendEvent` does not hand these synthetic mouse-downs to the view (in background runs, where the
    /// window is neither active nor key): AppKit queues each again and delivers it once through `NSApp.sendEvent`,
    /// after the second send, where the monitor logs it (`src=monitor`). The seam logs only `send <count>`, so each
    /// delivered mouse-down has one `click` line.
    /// `toolbargap` aims at the widest gap of the title bar row, past its first control, that hit-tests outside the
    /// toolbar items (the title bar container between the leading menus). `,direct` (`toolbar,direct`) hands each
    /// mouse-down straight to the hit view's `mouseDown(with:)`, past `NSWindow.sendEvent`; the seam logs it itself.
    /// `,opaque` turns `titlebarAppearsTransparent` off first (task 1.1: the transparent title bar was the cause).
    static func run(_ argument: String, in window: NSWindow) async {
        guard AppState.isStateDirMode else { return }
        let parts = argument.split(separator: ",").map(String.init)
        let row = parts.first ?? "", direct = parts.contains("direct")
        let point: NSPoint? = switch row {
        case "toolbar": toolbarPoint(in: window, outsideToolbar: false)
        case "toolbargap": toolbarPoint(in: window, outsideToolbar: true)
        case "tabrow": tabRowPoint(in: window)
        default: nil
        }
        guard let point else { return UITiming.probe("dblclick", "\(argument) no empty point found") }
        // Experiment: an opaque title bar.
        if parts.contains("opaque") { window.titlebarAppearsTransparent = false }
        UITiming.probe("dblclick", "\(argument) setup \(titlebarState(of: window))")
        let before = window.frame
        for count in 1...2 {
            let timestamp = ProcessInfo.processInfo.systemUptime
            guard let down = mouseEvent(.leftMouseDown, at: point, count: count, in: window, timestamp: timestamp),
                  let up = mouseEvent(.leftMouseUp, at: point, count: count, in: window, timestamp: timestamp + 0.01)
            else { return UITiming.probe("dblclick", "\(row) could not build events") }
            if direct { log(down, source: "seam") } else { UITiming.probe("dblclick", "\(row) send \(count)") }
            NSApp.postEvent(up, atStart: true)
            if direct, let hit = hitView(in: window, at: point) { hit.mouseDown(with: down) } else { window.sendEvent(down) }
            try? await Task.sleep(for: .milliseconds(60))
        }
        try? await Task.sleep(for: .milliseconds(500))
        UITiming.probe("dblclick", "\(argument) before=\(rect(before)) after=\(rect(window.frame)) "
            + "at=\(Int(point.x)),\(Int(point.y)) hit=\(name(hitView(in: window, at: point))) "
            + "zoomed=\(window.isZoomed) mini=\(window.isMiniaturized) movable=\(window.isMovable) "
            + "active=\(NSApp.isActive) key=\(window.isKeyWindow)")
        // A synthetic mouse-down may order the window in front: a background run puts it back.
        if AppState.isBackgroundLaunch { window.orderBack(nil) }
    }

    private static let titlebarFlag = "titlebarHandlesDoubleClickWhenTransparent"

    /// The title bar's double-click wiring: the private flag, and the title bar container's gesture recognizers.
    private static func titlebarState(of window: NSWindow) -> String {
        // A private key: read only where AppKit has it (a missing key raises).
        let flag = window.responds(to: NSSelectorFromString(titlebarFlag))
            ? (window.value(forKey: titlebarFlag) as? Bool).map(String.init) ?? "?" : "?"
        var container = window.standardWindowButton(.closeButton)?.superview
        while let view = container, name(view) != "NSTitlebarContainerView" { container = view.superview }
        let recognizers = container?.gestureRecognizers.map { recognizer in
            let clicks = (recognizer as? NSClickGestureRecognizer).map { "x\($0.numberOfClicksRequired)" } ?? ""
            return "\(String(describing: type(of: recognizer)))\(clicks):\(recognizer.isEnabled ? "on" : "off")"
        } ?? ["no container"]
        let fill = TitleBarDoubleClick.fillItem()?.action.map(NSStringFromSelector) ?? "none"
        return "transparent=\(window.titlebarAppearsTransparent) handlesWhenTransparent=\(flag) "
            + "container=[\(recognizers.joined(separator: ","))] fill=\(fill)"
    }

    /// Called by the window delegate's `windowShouldZoom`: one line per zoom, whoever asks for it.
    static func zoom(_ window: NSWindow, to frame: NSRect) {
        guard AppState.isStateDirMode else { return }
        UITiming.probe("zoom", "to=\(rect(frame)) from=\(rect(window.frame))")
    }

    private static func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, count: Int, in window: NSWindow,
                                   timestamp: TimeInterval) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: timestamp,
                           windowNumber: window.windowNumber, context: nil, eventNumber: count, clickCount: count,
                           pressure: type == .leftMouseDown ? 1 : 0)
    }

    /// The middle of the widest stretch of the title bar row, right of the traffic lights, that hit-tests to one view
    /// that is no toolbar control (the flexible space's item viewer, between the leading menus and the trailing
    /// buttons).
    private static func toolbarPoint(in window: NSWindow, outsideToolbar: Bool) -> NSPoint? {
        let y = (window.contentLayoutRect.maxY + window.frame.height) / 2
        let lights = window.standardWindowButton(.zoomButton).map { $0.convert($0.bounds, to: nil).maxX } ?? 80
        let xs = stride(from: lights + 8, to: window.frame.width - 4, by: 2).map { CGFloat($0) }
        let firstControl = xs.first { isControl(hitView(in: window, at: NSPoint(x: $0, y: y))) } ?? 0
        let point = widestRun(xs) { x in
            let view = hitView(in: window, at: NSPoint(x: x, y: y))
            guard !isControl(view), outsideToolbar ? x > firstControl : true else { return nil }
            return outsideToolbar == !isToolbarItem(view) ? view : nil
        }
        UITiming.probe("dblclick", "toolbar row y=\(Int(y)) \(rowMap(xs) { hitView(in: window, at: NSPoint(x: $0, y: y)) })")
        return point.map { NSPoint(x: $0, y: y) }
    }

    /// The middle of the widest stretch of the tab row that hit-tests to the `WindowDragView` itself.
    private static func tabRowPoint(in window: NSWindow) -> NSPoint? {
        guard let drag = dragView(in: window) else { return nil }
        let frame = drag.convert(drag.bounds, to: nil)
        let xs = stride(from: frame.minX + 2, to: frame.maxX - 2, by: 2).map { CGFloat($0) }
        let point = widestRun(xs) { x in hitView(in: window, at: NSPoint(x: x, y: frame.midY)) === drag ? drag : nil }
        if point == nil {
            UITiming.probe("dblclick", "tabrow: no x hit-tests to WindowDragView (hit at mid="
                + "\(name(hitView(in: window, at: NSPoint(x: frame.midX, y: frame.midY)))))")
        }
        return point.map { NSPoint(x: $0, y: frame.midY) }
    }

    /// The middle of the widest stretch of consecutive `xs` that hit-test to one and the same view (nil: not empty).
    private static func widestRun(_ xs: [CGFloat], emptyView: (CGFloat) -> NSView?) -> CGFloat? {
        var best: (start: CGFloat, end: CGFloat)?
        var run: (start: CGFloat, end: CGFloat, view: NSView)?
        for x in xs + [.infinity] {
            let view = x.isFinite ? emptyView(x) : nil
            if let view, let current = run, current.view === view {
                run?.end = x
                continue
            }
            if let current = run, best.map({ current.end - current.start > $0.end - $0.start }) ?? true {
                best = (current.start, current.end)
            }
            run = view.map { (x, x, $0) }
        }
        return best.map { ($0.start + $0.end) / 2 }
    }

    /// What the row hit-tests to, as runs: `<x0>-<x1>:<view class>[/<first control ancestor>]`.
    private static func rowMap(_ xs: [CGFloat], hit: (CGFloat) -> NSView?) -> String {
        var runs: [(start: CGFloat, end: CGFloat, label: String)] = []
        for x in xs {
            let view = hit(x)
            var label = name(view)
            var current = view?.superview
            while let ancestor = current, !(view is NSControl) {
                if ancestor is NSControl { label += "/" + name(ancestor); break }
                current = ancestor.superview
            }
            if let last = runs.last, last.label == label { runs[runs.count - 1].end = x } else { runs.append((x, x, label)) }
        }
        return runs.map { "\(Int($0.start))-\(Int($0.end)):\($0.label)" }.joined(separator: " ")
    }

    /// A toolbar item's view, or a view inside one.
    private static func isToolbarItem(_ view: NSView?) -> Bool {
        var current = view
        while let candidate = current {
            if name(candidate).hasPrefix("NSToolbarItem") { return true }
            current = candidate.superview
        }
        return false
    }

    /// A toolbar control, or a view inside one.
    private static func isControl(_ view: NSView?) -> Bool {
        var current = view
        while let candidate = current {
            if candidate is NSControl { return true }
            current = candidate.superview
        }
        return false
    }

    private static func rect(_ rect: NSRect) -> String {
        "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width))x\(Int(rect.height))"
    }
}
#endif

// MARK: - Native window tabs

extension NSWindow.TabbingIdentifier {
    /// Every repo window: they join one native tab group (Window › Merge All Windows, the tab bar's "+").
    static let histqDocument = NSWindow.TabbingIdentifier("com.math2it.histq.document")
}

/// What makes a repo window a native tab: the shared tabbing identifier, the "+" of the native tab bar and the title
/// its native tab shows. Its own toolbar (`HeaderToolbar`) stays: AppKit shows the selected tab's window with its
/// toolbar in row 1, the native tab bar in row 2 under it, and the content (the app's tab row first) starts below the
/// bar, at the top of the safe area.
@MainActor
enum DocumentWindow {
    /// Called once per window, before it shows. `openTab` opens a new Welcome window as a tab of the given window.
    static func configure(_ window: NSWindow, model: WindowModel, openTab: @escaping (NSWindow) -> Void) {
        window.tabbingIdentifier = .histqDocument
        window.tabbingMode = .automatic
        // Session restore (8.4) owns what windows reopen; AppKit restoring one would only bring back a bare window.
        window.isRestorable = false
        NewTabResponder.install(in: window, open: openTab)
        trackTitle(of: window, model: model)
    }

    /// Keeps `window.title` on the selected app tab's name ("New Tab" for a Welcome tab): the native tab, the Window
    /// menu and Mission Control show it; the title bar never draws it (`titleVisibility = .hidden`).
    private static func trackTitle(of window: NSWindow, model: WindowModel) {
        withObservationTracking {
            let title = model.selectedIndex.map { model.tabs[$0].title } ?? "Histq"
            if window.title != title { window.title = title }
        } onChange: { [weak window, weak model] in
            // Called before the change lands, off any isolation: read it on the main actor once it has.
            Task { @MainActor in
                guard let window, let model else { return }
                trackTitle(of: window, model: model)
            }
        }
    }
}

/// Answers the native tab bar's "+" (`newWindowForTab:`) right after the window, so the action knows which window's
/// tab group the new Welcome window joins (the app delegate, last in the chain, would only see the key window). AppKit
/// shows the "+" only while something in the window's responder chain answers it.
final class NewTabResponder: NSResponder {
    /// `nextResponder` does not retain: each window keeps its responder here.
    private static let responders = NSMapTable<NSWindow, NewTabResponder>.weakToStrongObjects()

    private weak var window: NSWindow?
    private let open: (NSWindow) -> Void

    private init(window: NSWindow, open: @escaping (NSWindow) -> Void) {
        self.window = window
        self.open = open
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    static func install(in window: NSWindow, open: @escaping (NSWindow) -> Void) {
        guard responders.object(forKey: window) == nil else { return }
        let responder = NewTabResponder(window: window, open: open)
        responder.nextResponder = window.nextResponder
        window.nextResponder = responder
        responders.setObject(responder, forKey: window)
    }

    override func newWindowForTab(_ sender: Any?) {
        guard let window else { return }
        open(window)
    }
}
