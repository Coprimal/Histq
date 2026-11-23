// What a spotlight can frame (`SpotlightTarget`) and where each one is (`SpotlightRegistry`, one per window): SwiftUI
// views report their frame with `.spotlightTarget(_:)`, AppKit views (the toolbar, the graph's rows) through providers.
// Frames are kept in window top-left coordinates, the space of SwiftUI's `.global` under `.fullSizeContentView`.
// Only the active target's changes are observed, so a frame report never wakes a view while no spotlight runs.
import AppKit
import Observation
import SwiftUI

/// A part of the window a spotlight can frame: the toolbar's items, then the content's areas.
enum SpotlightTarget: String, Hashable, CaseIterable {
    // Toolbar (`HeaderToolbar.frame(of:)`).
    case workspaceMenu, repoMenu, branchMenu, profile
    /// Undo / Redo, the whole capsule.
    case history
    /// Pull, Push and Fetch together.
    case sync
    /// Branch / Stash / Pop, the whole capsule.
    case branchActions
    /// The toolbar's Terminal and Search (command palette) buttons.
    case terminal, search
    // Content (`.spotlightTarget(_:)` or a provider).
    case tabStrip, verticalTabs, sidebarRefs, sidebarStashesWorktrees, sidebarPRs, graph, wipRow, detail, commitBox
    case staging, terminalDrawer

    /// Drawn by the toolbar, which AppKit draws above the SwiftUI content: dimmed by its own items, not by the layer.
    var isToolbar: Bool {
        switch self {
        case .workspaceMenu, .repoMenu, .branchMenu, .profile, .history, .sync, .branchActions, .terminal, .search: true
        default: false
        }
    }

    /// A button inside a toolbar row's capsule, whose glass (drawn above the layer) hides the layer's ring: the ring
    /// sits further out than the capsule's end inset, so even the end button (Terminal) loses it. The toolbar draws
    /// its ring instead (`HeaderToolbar`), on macOS 26.
    var hasToolbarRing: Bool { self == .search || self == .terminal }

    /// A toolbar dropdown, which has its own view on every macOS (the button items have one only on macOS 26).
    var isToolbarDropdown: Bool {
        switch self {
        case .workspaceMenu, .repoMenu, .branchMenu, .profile: true
        default: false
        }
    }
}

/// One window's spotlight targets and the spotlight showing in it (`activeTarget`). Frames are stored unobserved, so
/// views report them at no cost; `revision` changes only while a spotlight shows and only when its target's frame
/// does, which is all `SpotlightLayer` observes.
@Observable
@MainActor
final class SpotlightRegistry {
    /// The target a spotlight frames now; nil when none shows. Set by the DEBUG `-HistqSpotlight` flag and the tour.
    var activeTarget: SpotlightTarget? {
        didSet {
            isShowing = activeTarget != nil
            guard activeTarget != oldValue else { return }
            shownFrame = activeTarget.flatMap(frame(of:))
        }
    }
    /// Whether a spotlight shows (`activeTarget` is set), unobserved: an AppKit view's update may read it without
    /// depending on the target.
    @ObservationIgnored private(set) var isShowing = false

    /// Bumped when the active target's frame changes.
    private(set) var revision = 0
    /// The frames the SwiftUI targets reported, in window top-left coordinates, by the view that reported each part
    /// (a target can be several views, as the sidebar's cards of one group): a view clears only its own part, so a
    /// hidden tab's clear never wipes the shown tab's report.
    @ObservationIgnored private var frames: [SpotlightTarget: [ObjectIdentifier: CGRect]] = [:]
    /// The AppKit targets' frames, read when asked (the graph's WIP row), with the object that registered each.
    @ObservationIgnored private var providers: [SpotlightTarget: (owner: ObjectIdentifier, frame: () -> CGRect?)] = [:]
    /// The toolbar's items' frames (`HeaderToolbar.frame(of:)`); nil for a target it does not show.
    @ObservationIgnored var toolbarFrame: ((SpotlightTarget) -> CGRect?)?
    /// The active target's frame as last resolved, to bump `revision` only on a change.
    @ObservationIgnored private var shownFrame: CGRect?

    /// Where `target` is now in window top-left coordinates; nil when it is not shown (hidden panel, another tab, a
    /// toolbar item removed or in the overflow menu).
    func frame(of target: SpotlightTarget) -> CGRect? {
        if target.isToolbar { return toolbarFrame?(target) }
        if let frame = providers[target]?.frame() { return frame }
        guard let parts = frames[target]?.values, let first = parts.first else { return nil }
        return parts.dropFirst().reduce(first) { $0.union($1) }
    }

    /// `owner`'s part of `target` (nil once it is gone or hidden); the target is the union of its parts. An empty
    /// frame (a view that draws nothing) is no part.
    func setFrame(_ frame: CGRect?, for target: SpotlightTarget, owner: AnyObject) {
        let frame = frame?.isEmpty == false ? frame : nil
        let id = ObjectIdentifier(owner)
        guard frames[target]?[id] != frame else { return }
        frames[target, default: [:]][id] = frame
        if target == activeTarget { frameMayHaveChanged() }
    }

    /// An AppKit target's frame, read on demand; replaces another owner's provider.
    func register(_ target: SpotlightTarget, owner: AnyObject, provider: @escaping () -> CGRect?) {
        providers[target] = (ObjectIdentifier(owner), provider)
        if target == activeTarget { frameMayHaveChanged() }
    }

    /// Removes `owner`'s provider; nothing when another owner registered since.
    func unregister(_ target: SpotlightTarget, owner: AnyObject) {
        guard providers[target]?.owner == ObjectIdentifier(owner) else { return }
        providers[target] = nil
        if target == activeTarget { frameMayHaveChanged() }
    }

    /// A provider's view may have moved (the toolbar laid out, the window resized): bumps `revision` when the active
    /// target's frame differs from the one last shown.
    func frameMayHaveChanged() {
        guard let activeTarget else { return }
        let frame = frame(of: activeTarget)
        guard frame != shownFrame else { return }
        shownFrame = frame
        revision &+= 1
        #if DEBUG || HISTQ_PERF
        let text = frame.map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width)),\(Int($0.height))" } ?? "nil"
        UITiming.spotlight("\(activeTarget.rawValue) frame=\(text)")
        #endif
    }
}

extension View {
    /// Reports this view's frame to the window's spotlight registry as `target`, while its tab shows (a hidden kept
    /// tab's views stay mounted, so they clear it) and until it disappears. Several views with one target make it their
    /// union.
    func spotlightTarget(_ target: SpotlightTarget) -> some View {
        modifier(SpotlightTargetModifier(target: target))
    }
}

private struct SpotlightTargetModifier: ViewModifier {
    let target: SpotlightTarget
    @Environment(WindowModel.self) private var model
    @Environment(\.tabIsShown) private var tabIsShown
    /// The last frame, kept out of the view's state so a report re-evaluates nothing; also this view's part's key in
    /// the registry.
    @State private var last = LastFrame()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                last.frame = frame
                if tabIsShown { model.spotlight.setFrame(frame, for: target, owner: last) }
            }
            .onChange(of: tabIsShown) { _, shown in
                model.spotlight.setFrame(shown ? last.frame : nil, for: target, owner: last)
            }
            // A view whose target follows its state (the sidebar's tab row) moves its part over: its frame may not
            // change, so no geometry report would.
            .onChange(of: target) { old, new in
                model.spotlight.setFrame(nil, for: old, owner: last)
                model.spotlight.setFrame(tabIsShown ? last.frame : nil, for: new, owner: last)
            }
            .onDisappear { model.spotlight.setFrame(nil, for: target, owner: last) }
    }

    private final class LastFrame {
        var frame: CGRect?
    }
}
