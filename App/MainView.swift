// The main window: the toolbar in the traffic-light row (`HeaderToolbar`), the tab strip under it (or the vertical
// tabs, panel 0, left of the page), then the selected page, over the window glass. Settings is a modal over it
// (`ModalHost`).
import AppKit
import SwiftUI

/// A page of the window, left to right in the slide order: the selected tab.
enum Page: String, CaseIterable, Hashable {
    case home

    /// Its place in the order, for the slide direction.
    fileprivate var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// The selected page, owned by the AppDelegate so its menus can open a page before the window exists.
@Observable
@MainActor
final class Navigation {
    var page: Page = .home {
        didSet { forward = page.order >= oldValue.order }
    }

    /// The last page change went to a page further right.
    private(set) var forward = true
}

/// The rows under the toolbar. The tab strip starts at the top of the safe area, so it sits under the toolbar, and
/// under the native window tab bar when one shows (Phase 8).
enum HeaderMetrics {
    /// The tab row and the page's sheet from the window's edges: the panels' inset.
    static let tabStripInset: CGFloat = RepoLayoutMetrics.inset
    /// Above the tabs, under the toolbar. The tabs' bottom is the sheet's top: the selected tab joins it.
    static let tabRowTop: CGFloat = 0
    /// Before the first tab: the sheet's corner, so the selected tab's flare sits on its straight top edge.
    static let tabRowLeading: CGFloat = PageSheetMetrics.cornerRadius
    /// After New Tab and the tab list.
    static let tabRowTrailing: CGFloat = 4
}

/// The one container around the selected tab's page (the repo panels' cards, Welcome), joined to the selected
/// tab when the tabs are on top.
enum PageSheetMetrics {
    /// Concentric with the cards inside it, `RepoLayoutMetrics.inset` from its edge.
    static let cornerRadius: CGFloat = SettingsMetrics.cardRadius + RepoLayoutMetrics.inset
    /// Added around the content of the cards on it (`cardExtraPadding`, `cardExtraVerticalPadding`), so it sits clear
    /// of their edges: a little on the sides, more above and below.
    static let cardExtraPadding: CGFloat = 2
    static let cardExtraVerticalPadding: CGFloat = 6
}

struct MainView: View {
    @Bindable var navigation: Navigation
    @Environment(WindowModel.self) private var model
    /// The page on screen; it follows `navigation.page` with a slide.
    @State private var shownPage = Page.home
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// General › Tab position, applied live.
    @AppStorage(PrefKey.tabPosition.rawValue, store: Preferences.defaults) private var tabPosition = "top"

    var body: some View {
        let tabsOnLeft = TabPosition.resolved(tabPosition) == .left
        VStack(spacing: 0) {
            if !tabsOnLeft { tabRow }
            // The pages keep one place in the tree in both positions, so switching the position (from the Settings
            // modal over it) never rebuilds the page on screen.
            HStack(spacing: 0) {
                if tabsOnLeft {
                    // No gap after it: its selected row joins the sheet's left edge.
                    VerticalTabsPanel()
                        .padding([.leading, .bottom], HeaderMetrics.tabStripInset)
                }
                // Rendered from `shownPage`, so the leaving page keeps its content while it slides out. All of it on
                // one sheet (`Palette.sheet`, the selected tab's fill), its cards a step darker.
                ZStack {
                    switch shownPage {
                    case .home: TabContent().transition(pageTransition)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.cardSurface, Palette.sheetCard)
                .environment(\.cardExtraPadding, PageSheetMetrics.cardExtraPadding)
                .environment(\.cardExtraVerticalPadding, PageSheetMetrics.cardExtraVerticalPadding)
                .background(Palette.sheet)
                .clipShape(RoundedRectangle(cornerRadius: PageSheetMetrics.cornerRadius, style: .continuous))
                .padding(tabsOnLeft ? [.trailing, .bottom] : [.horizontal, .bottom], HeaderMetrics.tabStripInset)
            }
        }
        // Blurred and disabled behind a modal or the palette; its own view reads that, so this body never reruns.
        .modifier(WindowBackdrop(model: model))
        // Whoever switches the page (a tab, a menu), it slides the same way.
        .onChange(of: navigation.page, initial: true) { old, new in
            guard old != new else {
                shownPage = new
                return
            }
            withAnimation(Motion.standard) { shownPage = new }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowGlass().ignoresSafeArea())
        // A band behind the toolbar row (drawn above it by AppKit), so scrolled content never shows through the
        // transparent title bar; the same glass as the window, so toolbar and content still read as one.
        .overlay {
            GeometryReader { proxy in
                WindowGlass()
                    .frame(height: proxy.safeAreaInsets.top)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea(.container, edges: .top)
            }
            .allowsHitTesting(false)
        }
        // The operations' outcomes at the bottom right, under the palette and the modals.
        .overlay(alignment: .bottomTrailing) { ToastHost(model: model) }
        // ⌘K / the toolbar's Search: over the tabs and the page, under the toolbar.
        .overlay { CommandPaletteOverlay(model: model) }
        // Settings, the forms, confirmations and rebase cards, drawn like the palette (same place in the window).
        .overlay { ModalHost(model: model) }
        .modifier(HardTopScrollEdge())
    }

    /// The tab strip, full width under the toolbar, then the menus' running operation, on the window glass: no
    /// container, the selected tab joins the page's sheet under it. Empty space in the row drags the window, like the
    /// toolbar's.
    private var tabRow: some View {
        HStack(spacing: 0) {
            TabStrip()
            TabRowStatus(model: model)
        }
        .padding(.top, HeaderMetrics.tabRowTop)
        .padding(.leading, HeaderMetrics.tabRowLeading)
        .padding(.trailing, HeaderMetrics.tabRowTrailing)
        .background(WindowDragArea())
        .padding(.horizontal, HeaderMetrics.tabStripInset)
    }

    /// Pages slide a little in their order; the leaving page fades out faster, so the two never show through each
    /// other. A fade only under Reduce Motion.
    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let travel: CGFloat = navigation.forward ? 24 : -24
        return .asymmetric(
            insertion: .offset(x: travel).combined(with: .opacity),
            removal: .offset(x: -travel).combined(with: .opacity).animation(Motion.exit))
    }
}

/// Applies `ModalBackdrop` while the window shows Settings, a modal or the palette. Only this modifier reads that
/// state.
private struct WindowBackdrop: ViewModifier {
    let model: WindowModel

    func body(content: Content) -> some View {
        content.modifier(ModalBackdrop(isActive: model.isShowingModal))
    }
}

/// The selected tab's area: the three-panel layout of a repo tab, "Repo not found" for a restored repo that is gone,
/// or the Welcome page of a new tab. A new identity
/// per tab: switching tabs shows the new tab's placeholder (or its Welcome state), never the old tab's view.
private struct TabContent: View {
    @Environment(WindowModel.self) private var model

    var body: some View {
        // In a container, so the page's slide (`MainView.pageTransition`) applies to this page as a whole and not to
        // each tab's view: a tab switch swaps them in one frame, the old tab never slides out over the new one.
        ZStack {
            if let session = model.selectedSession {
                RepoLayoutView(session: session).id(session.id)
            } else if let index = model.selectedIndex, model.tabs[index].isMissing, let url = model.tabs[index].repoURL {
                RepoNotFoundView(model: model, tabID: model.tabs[index].id, url: url).id(model.tabs[index].id)
            } else if let id = model.selectedTabID {
                WelcomeView(model: model.welcome(for: id)).id(id)
            }
        }
    }
}

/// The selected repo's operations started from a menu (a merge, a rebase…), which have no toolbar button to show
/// their progress on.
private struct TabRowStatus: View {
    let model: WindowModel

    var body: some View {
        if let session = model.selectedSession {
            RunningStatus(session: session)
                .frame(maxWidth: 240, alignment: .trailing)
                .padding(.trailing, 8)
        }
    }
}
