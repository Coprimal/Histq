// The main window: the toolbar in the traffic-light row (`HeaderToolbar`), the tab strip under it (or the vertical
// tabs, panel 0, left of the page), then the selected page, then the footer (`WindowFooter`), over the window glass.
// Settings is a modal over it (`ModalHost`).
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
    @AppStorage(PrefKey.cardBorders.rawValue, store: Preferences.defaults) private var cardBorders = true

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
                        .padding(.leading, HeaderMetrics.tabStripInset)
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
                .environment(\.cardBorder, cardBorders ? Palette.sheetCardBorder : .clear)
                .environment(\.cardExtraPadding, PageSheetMetrics.cardExtraPadding)
                .environment(\.cardExtraVerticalPadding, PageSheetMetrics.cardExtraVerticalPadding)
                .background(Palette.sheet)
                .clipShape(RoundedRectangle(cornerRadius: PageSheetMetrics.cornerRadius, style: .continuous))
                .padding(tabsOnLeft ? .trailing : .horizontal, HeaderMetrics.tabStripInset)
            }
            // Its height is the gap under the sheet.
            WindowFooter(model: model)
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
        // The operations' outcomes at the bottom right, above the footer, under the palette and the modals.
        .overlay(alignment: .bottomTrailing) { ToastHost(model: model).padding(.bottom, WindowFooter.height) }
        // ⌘K / the toolbar's Search: over the tabs and the page, under the toolbar.
        .overlay { CommandPaletteOverlay(model: model) }
        // The first-run onboarding's card: over the palette's place, under Settings and the modals it may open.
        .overlay { OnboardingOverlay(model: model) }
        // Settings, the forms, confirmations and rebase cards, drawn like the palette (same place in the window).
        .overlay { ModalHost(model: model) }
        // A spotlight over everything (the tour, DEBUG `-HistqSpotlight`): it dims the window, the toolbar its own
        // items.
        .overlay { SpotlightOverlay(model: model) }
        .modifier(HardTopScrollEdge())
    }

    /// The tab strip, full width under the toolbar, on the window glass: no container, the selected tab joins the
    /// page's sheet under it. Empty space in the row drags the window, like the toolbar's.
    private var tabRow: some View {
        TabStrip()
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

/// The onboarding's card while it runs over the window (`WindowModel.onboarding`), disabled while Settings or a modal
/// (the window's or the tab's) covers it. Only this view reads that state, so `MainView`'s body never reruns for it.
private struct OnboardingOverlay: View {
    let model: WindowModel

    var body: some View {
        if let onboarding = model.onboarding {
            OnboardingCard(
                model: onboarding,
                isCovered: model.isSettingsOpen || model.modal != nil || model.actionSession?.hasModal == true,
                onOpenSettings: { model.openSettings() })
        }
    }
}

/// The selected tab's area: the three-panel layout of a repo tab, "Repo not found" for a restored repo that is gone,
/// or the Welcome page of a new tab. The last tabs shown (`WindowModel.recentlyShown`) keep their layout mounted,
/// hidden while another tab shows, so a switch back shows the tab as it was without building it again. "Repo not
/// found" and Welcome get a new identity per tab: a switch never shows the old tab's page.
private struct TabContent: View {
    @Environment(WindowModel.self) private var model

    var body: some View {
        let selected = model.selectedSession
        // In tab order, not most recent first: a switch moves no layout in the stack. The selected one is there even
        // before `recentlyShown` has it.
        let kept = model.tabs.compactMap { tab in
            model.recentlyShown.contains(tab.id) || tab.id == model.selectedTabID ? model.sessions[tab.id] : nil
        }
        // In a container, so the page's slide (`MainView.pageTransition`) applies to this page as a whole and not to
        // each tab's view: a tab switch swaps them in one frame, the old tab never slides out over the new one.
        ZStack {
            // A hidden layout takes no clicks, no keys (its shortcuts are off), is not read by VoiceOver, and its
            // AppKit views and background work follow `tabIsShown`.
            ForEach(kept) { session in
                let isShown = session === selected
                RepoLayoutView(session: session)
                    .equatable()
                    .opacity(isShown ? 1 : 0)
                    .allowsHitTesting(isShown)
                    .accessibilityHidden(!isShown)
                    .disabled(!isShown)
                    .environment(\.tabIsShown, isShown)
            }
            if selected == nil {
                if let index = model.selectedIndex, model.tabs[index].isMissing, let url = model.tabs[index].repoURL {
                    RepoNotFoundView(model: model, tabID: model.tabs[index].id, url: url).id(model.tabs[index].id)
                } else if let id = model.selectedTabID {
                    WelcomeView(model: model.welcome(for: id)).id(id)
                }
            }
        }
        // Every switch, whether or not the tab's view is rebuilt: the shown tab takes the keyboard in this update.
        .onChange(of: model.selectedTabID) {
            let repo = model.selectedIndex.flatMap { model.tabs[$0].repoURL?.lastPathComponent } ?? "-"
            UITiming.tabShown("\(model.selectedIndex ?? -1) \(repo)")
            model.focusShownTab(repo: repo)
        }
        #if DEBUG
        .task { await model.debugTabWalk() }
        #endif
    }
}

/// The row under the page, on the window glass: Sidebar, the selected repo's folder and its running operation (any
/// write, GitHub action or patch export, from the click's frame on: `RunningStatus`) at the leading edge, Histq's
/// version and Detail at the trailing edge. A fixed height, so a status coming and going never moves the page.
struct WindowFooter: View {
    let model: WindowModel
    static let height: CGFloat = 30
    @AppStorage(PrefKey.showSidebar.rawValue, store: Preferences.defaults) private var sidebarShown = true
    @AppStorage(PrefKey.showDetail.rawValue, store: Preferences.defaults) private var detailShown = true
    @AppStorage(PrefKey.layoutPreset.rawValue, store: Preferences.defaults) private var storedPreset = "classic"

    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    /// A step above `settingsCaption` (user, 2026-11-20): the footer's text and its toggles' icons.
    private static let textFont: Font = .callout
    private static let iconFont: Font = .system(size: 15)

    var body: some View {
        // Each toggle is off while its panel is hidden whatever it says (`RepoLayoutView`): without a repo tab, in
        // Focus, and (Detail) while a pull request is open outside Stacked.
        let session = model.actionSession
        let preset = LayoutPreset.resolved(storedPreset)
        HStack(spacing: 12) {
            toggle("Sidebar", systemImage: "sidebar.left", shown: $sidebarShown)
                .disabled(session == nil || preset == .focus)
            if let session {
                // The repo's folder, shortened in the middle before the running status gives way.
                let path = (session.url.path as NSString).abbreviatingWithTildeInPath
                Text(path)
                    .font(Self.textFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
                    .layoutPriority(-2)
                RunningStatus(session: session, font: Self.textFont)
            }
            Spacer(minLength: 0)
            Text("v\(Self.version)")
                .font(Self.textFont.monospaced())
                .foregroundStyle(.secondary)
            toggle("Detail", systemImage: "sidebar.right", shown: $detailShown)
                .disabled(session.map { RepoLayoutView.hidesDetail(session: $0, preset: preset) } ?? true)
        }
        .padding(.horizontal, PageSheetMetrics.cornerRadius)
        .frame(height: Self.height)
    }

    private func toggle(_ name: String, systemImage: String, shown: Binding<Bool>) -> some View {
        let help = (shown.wrappedValue ? "Hide " : "Show ") + name
        return Button { shown.wrappedValue.toggle() } label: {
            Label(help, systemImage: systemImage).labelStyle(.iconOnly).font(Self.iconFont)
        }
        .buttonStyle(RowIconButtonStyle())
        .foregroundStyle(.secondary)
        .help(help)
    }
}
