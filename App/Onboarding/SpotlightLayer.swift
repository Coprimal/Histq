// The spotlight over a window: all dimmed but a rounded cutout and blue ring around the target, joined by a line to a
// popover (title, text, icon chips, the tour's controls) placed where it fits. It takes every click and every key of its
// window (← → Return Esc: Back / Next / Next / Skip; ⌘Q and ⌘H pass). The toolbar, drawn by AppKit above it, dims its
// own items (`HeaderToolbar`); a toolbar target without a view anchors to the toolbar band.
import AppKit
import SwiftUI

/// What a spotlight's popover says.
struct SpotlightPopover: Equatable {
    var title: String
    var message: String
    /// SF Symbols or Lucide assets (`IconImage`), shown as chips under the text.
    var icons: [String] = []
    /// What each icon means, as rows under the text (the graph's ref badges).
    var legend: [SpotlightLegendRow] = []
}

/// A legend row: an icon (SF Symbol or Lucide asset) or a few characters drawn as the app draws them, and its meaning.
struct SpotlightLegendRow: Equatable {
    enum Mark: Equatable {
        case icon(String)
        case text(String)
    }

    var mark: Mark
    var text: String
}

/// The tour's controls in a popover: where the stop is in the tour (Back, Next and Skip are the layer's own actions).
struct SpotlightTourControls {
    /// The stop's position, from 1.
    var position: Int
    var count: Int
}

/// The spotlight while `registry.activeTarget` is set: the onboarding's tour stop with its controls, else (DEBUG
/// `-HistqSpotlight`) a sample popover that Return or Esc ends. Only this view reads that state, so `MainView`'s body
/// never reruns for it.
struct SpotlightOverlay: View {
    let model: WindowModel

    var body: some View {
        let registry = model.spotlight
        if let target = registry.activeTarget {
            if let onboarding = model.onboarding, let stop = onboarding.currentStop {
                SpotlightLayer(
                    registry: registry, target: target, popover: stop.popover,
                    tour: SpotlightTourControls(position: onboarding.stopIndex + 1,
                                                count: onboarding.tourStops.count),
                    onBack: { onboarding.previousStop() }, onNext: { onboarding.nextStop() },
                    onSkip: { onboarding.skipTour() })
            } else {
                SpotlightLayer(registry: registry, target: target, popover: Self.sample(target),
                               onNext: { registry.activeTarget = nil }, onSkip: { registry.activeTarget = nil })
            }
        }
    }

    /// The DEBUG flag's popover.
    private static func sample(_ target: SpotlightTarget) -> SpotlightPopover {
        switch target {
        case .sync:
            SpotlightPopover(
                title: "Pull, Push and Fetch",
                message: "Pull brings the current branch up to date, Push sends your commits, and Fetch reads every "
                    + "remote without touching your branches.",
                icons: [ToolbarAction.pull.systemImage, ToolbarAction.push.systemImage,
                        ToolbarAction.fetch.systemImage])
        default:
            SpotlightPopover(title: target.rawValue, message: "A sample popover for this spotlight target.")
        }
    }
}

enum SpotlightMetrics {
    /// Between the target and the cutout (and its ring).
    static let padding: CGFloat = 8
    static let ringWidth: CGFloat = 2
    static let lineWidth: CGFloat = 1.5
    /// The dot at the line's target end.
    static let dotDiameter: CGFloat = 7
    /// Between the ring and the popover: the line's length when they face each other.
    static let gap: CGFloat = 28
    static let popoverWidth: CGFloat = 300
    static let popoverRadius: CGFloat = 14
    static let popoverInset: CGFloat = 10
}

/// One spotlight: the dim with its cutout, the ring, the line and the popover, laid out in window top-left
/// coordinates (it ignores the safe area, so its space is SwiftUI's `.global`).
struct SpotlightLayer: View {
    let registry: SpotlightRegistry
    let target: SpotlightTarget
    let popover: SpotlightPopover
    /// The tour's controls under the popover's text; none for the DEBUG sample.
    var tour: SpotlightTourControls?
    var onBack: () -> Void = {}
    var onNext: () -> Void = {}
    var onSkip: () -> Void = {}
    /// The popover's measured size; a guess until its first layout.
    @State private var popoverSize = CGSize(width: SpotlightMetrics.popoverWidth, height: 120)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The outer reader stays in the safe area to read the toolbar band's height; the inner one covers the window.
        GeometryReader { outer in
            let band = outer.safeAreaInsets.top
            GeometryReader { proxy in
                // Redrawn when the target's frame changes (the registry bumps it only then).
                let _ = registry.revision
                let origin = proxy.frame(in: .global).origin
                let anchor = registry.frame(of: target).map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
                let layout = SpotlightLayout(anchor: anchor, isToolbar: target.isToolbar, size: proxy.size,
                                             band: band, popover: popoverSize)
                content(layout)
            }
            .ignoresSafeArea()
        }
        .background(SpotlightKeys(onKey: handle, onLayout: { registry.frameMayHaveChanged() }))
    }

    private func content(_ layout: SpotlightLayout) -> some View {
        ZStack(alignment: .topLeading) {
            // The whole window takes the clicks, the cutout too: only the popover is live.
            SpotlightDim(cutout: layout.cutout ?? .zero, radius: layout.radius)
                .fill(Palette.spotlightScrim, style: FillStyle(eoFill: true))
                .contentShape(Rectangle())
                .onTapGesture {}
                .accessibilityHidden(true)
            if let ring = layout.ring, !target.hasToolbarRing {
                RoundedRectangle(cornerRadius: layout.radius, style: .continuous)
                    .strokeBorder(Palette.spotlightRing, lineWidth: SpotlightMetrics.ringWidth)
                    .frame(width: ring.width, height: ring.height)
                    .position(x: ring.midX, y: ring.midY)
                    .allowsHitTesting(false)
            }
            if let line = layout.line {
                SpotlightLine(from: line.from, to: line.to)
                    .stroke(Palette.spotlightRing,
                            style: StrokeStyle(lineWidth: SpotlightMetrics.lineWidth, lineCap: .round))
                    .allowsHitTesting(false)
                Circle()
                    .fill(Palette.spotlightRing)
                    .frame(width: SpotlightMetrics.dotDiameter, height: SpotlightMetrics.dotDiameter)
                    .position(line.to)
                    .allowsHitTesting(false)
            }
            SpotlightPopoverView(popover: popover, tour: tour, onBack: onBack, onNext: onNext, onSkip: onSkip)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { popoverSize = $0 }
                .position(x: layout.popover.midX, y: layout.popover.midY)
        }
        // From one target to the next; a window resize or the popover's first measure moves it at once.
        .animation(reduceMotion ? nil : Motion.standard, value: target)
    }

    private func handle(_ key: SpotlightKey) {
        switch key {
        case .back: onBack()
        case .next: onNext()
        case .skip: onSkip()
        }
    }
}

// MARK: - Layout

/// Where the spotlight's parts go for a target at `anchor` (nil: not shown) in a window of `size`, under a toolbar
/// band `band` high.
struct SpotlightLayout: Equatable {
    /// The undimmed part; nil dims the whole window.
    var cutout: CGRect?
    var radius: CGFloat = 0
    var ring: CGRect?
    var popover: CGRect
    var line: Line?

    struct Line: Equatable {
        var from: CGPoint
        var to: CGPoint
    }

    private enum Side { case below, above, right, left }

    @MainActor
    init(anchor: CGRect?, isToolbar: Bool, size: CGSize, band: CGFloat, popover: CGSize) {
        // The window less its margin; at the top, the toolbar band (a popover under a toolbar item starts right
        // under it).
        let margin = ModalMetrics.margin
        let top = max(band, margin)
        let bounds = CGRect(x: margin, y: top, width: max(size.width - 2 * margin, 0),
                            height: max(size.height - top - margin, 0))
        let target: CGRect
        if let anchor {
            let ring = anchor.insetBy(dx: -SpotlightMetrics.padding, dy: -SpotlightMetrics.padding)
            target = ring
            self.ring = ring
            cutout = ring
            // A capsule around a toolbar item; a card's corner around a panel.
            radius = isToolbar ? ring.height / 2 : SettingsMetrics.cardRadius + SpotlightMetrics.padding
        } else if isToolbar {
            // A toolbar item without a view (before macOS 26): the whole band, left undimmed, no ring.
            target = CGRect(x: 0, y: 0, width: size.width, height: band)
            cutout = target
        } else {
            // Not shown: the popover alone, in the middle.
            self.popover = Self.clamped(CGRect(x: bounds.midX - popover.width / 2, y: bounds.midY - popover.height / 2,
                                               width: popover.width, height: popover.height), in: bounds)
            return
        }
        guard let (side, frame) = Self.place(popover, around: target, in: bounds) else {
            // No side has room (a target nearly the window's size): the popover inside it, no line.
            self.popover = Self.clamped(CGRect(x: target.midX - popover.width / 2,
                                               y: target.maxY - popover.height - margin,
                                               width: popover.width, height: popover.height), in: bounds)
            return
        }
        self.popover = frame
        line = Self.line(from: frame, to: target, side: side, targetRadius: anchor == nil ? 0 : radius)
    }

    /// The first side of `target` where the popover fits in `bounds`, below, above, right, then left, clamped along
    /// the other axis.
    private static func place(_ size: CGSize, around target: CGRect, in bounds: CGRect) -> (Side, CGRect)? {
        let gap = SpotlightMetrics.gap
        let centeredX = target.midX - size.width / 2, centeredY = target.midY - size.height / 2
        let candidates: [(Side, CGRect)] = [
            (.below, CGRect(x: centeredX, y: target.maxY + gap, width: size.width, height: size.height)),
            (.above, CGRect(x: centeredX, y: target.minY - gap - size.height, width: size.width, height: size.height)),
            (.right, CGRect(x: target.maxX + gap, y: centeredY, width: size.width, height: size.height)),
            (.left, CGRect(x: target.minX - gap - size.width, y: centeredY, width: size.width, height: size.height)),
        ]
        for (side, frame) in candidates {
            let fits = switch side {
            case .below, .above:
                frame.minY >= bounds.minY && frame.maxY <= bounds.maxY && size.width <= bounds.width
            case .right, .left:
                frame.minX >= bounds.minX && frame.maxX <= bounds.maxX && size.height <= bounds.height
            }
            if fits { return (side, clamped(frame, in: bounds)) }
        }
        return nil
    }

    /// `frame` moved inside `bounds` (its top-left edge wins when it is bigger).
    private static func clamped(_ frame: CGRect, in bounds: CGRect) -> CGRect {
        var frame = frame
        frame.origin.x = max(min(frame.minX, bounds.maxX - frame.width), bounds.minX)
        frame.origin.y = max(min(frame.minY, bounds.maxY - frame.height), bounds.minY)
        return frame
    }

    /// From the popover's edge facing the target to the target's facing edge, kept off both rounded corners.
    private static func line(from popover: CGRect, to target: CGRect, side: Side, targetRadius: CGFloat) -> Line {
        func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            low > high ? (low + high) / 2 : min(max(value, low), high)
        }
        let inset = SpotlightMetrics.popoverRadius
        let targetInset = min(targetRadius, min(target.width, target.height) / 2)
        switch side {
        case .below, .above:
            let x = clamp(target.midX, popover.minX + inset, popover.maxX - inset)
            let toX = clamp(x, target.minX + targetInset, target.maxX - targetInset)
            return side == .below
                ? Line(from: CGPoint(x: x, y: popover.minY), to: CGPoint(x: toX, y: target.maxY))
                : Line(from: CGPoint(x: x, y: popover.maxY), to: CGPoint(x: toX, y: target.minY))
        case .right, .left:
            let y = clamp(target.midY, popover.minY + inset, popover.maxY - inset)
            let toY = clamp(y, target.minY + targetInset, target.maxY - targetInset)
            return side == .right
                ? Line(from: CGPoint(x: popover.minX, y: y), to: CGPoint(x: target.maxX, y: toY))
                : Line(from: CGPoint(x: popover.maxX, y: y), to: CGPoint(x: target.minX, y: toY))
        }
    }
}

// MARK: - Shapes

/// The whole rect but a rounded cutout (even-odd fill), which animates from one target to the next.
private struct SpotlightDim: Shape {
    var cutout: CGRect
    var radius: CGFloat

    var animatableData: AnimatablePair<CGRect.AnimatableData, CGFloat> {
        get { AnimatablePair(cutout.animatableData, radius) }
        set {
            cutout.animatableData = newValue.first
            radius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        if !cutout.isEmpty {
            path.addRoundedRect(in: cutout, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
        }
        return path
    }
}

private struct SpotlightLine: Shape {
    var from: CGPoint
    var to: CGPoint

    var animatableData: AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData> {
        get { AnimatablePair(from.animatableData, to.animatableData) }
        set {
            from.animatableData = newValue.first
            to.animatableData = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        return path
    }
}

// MARK: - Popover

private struct SpotlightPopoverView: View {
    let popover: SpotlightPopover
    let tour: SpotlightTourControls?
    let onBack: () -> Void
    let onNext: () -> Void
    let onSkip: () -> Void

    var body: some View {
        PanelContainer(cornerRadius: SpotlightMetrics.popoverRadius) {
            VStack(alignment: .leading, spacing: 8) {
                // Skip leaves the tour; only the tour's popover has it (a sample ends with Return or Esc).
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // Plain text: the copy is the app's own.
                    Text(popover.title)
                        .font(.headline)
                    Spacer(minLength: 0)
                    if tour != nil {
                        Button("Skip", action: onSkip)
                            .buttonStyle(RowTextButtonStyle())
                    }
                }
                Text(popover.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !popover.legend.isEmpty { legend }
                if !popover.icons.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(popover.icons, id: \.self) { name in
                            IconImage(name, size: 13)
                                .frame(width: 28, height: 22)
                                .background(Capsule().fill(Palette.tabFill))
                        }
                    }
                }
                if let tour { controls(tour) }
            }
            .padding(SpotlightMetrics.popoverInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: SpotlightMetrics.popoverWidth)
        .fixedSize(horizontal: false, vertical: true)
        .shadow(color: Palette.cardShadow, radius: 16, y: 6)
    }

    /// One row per legend entry: the mark in a fixed column (wide enough for "↑2 ↓1"), so the texts line up.
    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(popover.legend.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Group {
                        switch row.mark {
                        case .icon(let name): IconImage(name, size: 13)
                        case .text(let text): Text(verbatim: text).monospacedDigit()
                        }
                    }
                    .frame(width: 40, alignment: .center)
                    Text(row.text)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            }
        }
    }

    /// The counter with Back / Next (Skip is in the header). No key equivalents: the layer's key monitor owns the keys.
    private func controls(_ tour: SpotlightTourControls) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: "\(tour.position) / \(tour.count)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Stop \(tour.position) of \(tour.count)")
            Spacer(minLength: 0)
            Button("Back", action: onBack)
                .buttonStyle(RowTextButtonStyle(formRow: true))
            Button("Next", action: onNext)
                .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
        }
        .padding(.top, 4)
    }
}

// MARK: - Keys

enum SpotlightKey { case back, next, skip }

/// Holds the window's keyboard while the spotlight shows: its view becomes the first responder, and a local monitor
/// takes every key-down of this window (other windows' pass unchanged): ← is Back, → and Return are Next, Esc is Skip,
/// ⌘Q and ⌘H go on, the rest is dropped, so no key reaches the content. It also tells the registry when the window
/// resizes, so a toolbar target's frame is read again. Both end when the spotlight leaves the window.
private struct SpotlightKeys: NSViewRepresentable {
    let onKey: (SpotlightKey) -> Void
    let onLayout: () -> Void

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.onKey = onKey
        nsView.onLayout = onLayout
    }

    static func dismantleNSView(_ nsView: KeyView, coordinator: ()) { nsView.stop() }

    final class KeyView: NSView {
        var onKey: (SpotlightKey) -> Void = { _ in }
        var onLayout: () -> Void = {}
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []

        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {}
        override nonisolated func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            window.makeFirstResponder(self)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let eventWindow = event.window
                let keyCode = event.keyCode
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let characters = event.charactersIgnoringModifiers?.lowercased()
                let taken = MainActor.assumeIsolated {
                    self?.take(window: eventWindow, keyCode: keyCode, flags: flags, characters: characters) ?? false
                }
                return taken ? nil : event
            }
            observers = [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.layoutChanged() }
                }
            }
            // The toolbar lays out with the window's first display: read its frames once it has.
            layoutChanged()
        }

        /// Whether the key is the spotlight's (every key of its window but ⌘Q and ⌘H).
        private func take(window eventWindow: NSWindow?, keyCode: UInt16, flags: NSEvent.ModifierFlags,
                          characters: String?) -> Bool
        {
            guard let window, eventWindow === window else { return false }
            if flags.subtracting([.capsLock, .function, .numericPad]) == .command,
               characters == "q" || characters == "h" { return false }
            let plain = flags.subtracting([.function, .numericPad, .capsLock]).isEmpty
            guard plain else { return true }
            switch keyCode {
            case 123: onKey(.back)
            case 124, 36, 76: onKey(.next)
            case 53: onKey(.skip)
            default: break
            }
            return true
        }

        private func layoutChanged() {
            DispatchQueue.main.async { [weak self] in self?.onLayout() }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }
    }
}
