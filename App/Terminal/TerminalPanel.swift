// The integrated terminal (task 13.1): a drawer at the bottom of panel 2 with one SwiftTerm `LocalProcessTerminalView`
// per repo tab. The tab's `RepoSession` owns it (`RepoTerminal`), so a tab switch or closing the drawer only takes the
// view out of the window: the shell keeps running until the tab or the window closes.
//
// The shell is the user's login shell, started as a login shell in the repo folder with the user's own environment
// plus the tab's profile (`GitInvocation.terminalProcessEnvironment(base:profile:)`: identity, signing, SSH key file).
// It never gets an account token or Histq's credential helper: what the user types there runs with their own
// credentials, as in Terminal.app. It starts only when the user asks for it: a drawer shown with each new tab waits
// for a click, since a shell prompt runs git in the repo, whose own config may run commands.
import AppKit
import HistqCore
@preconcurrency import SwiftTerm
import SwiftUI

/// Sizes of the terminal drawer.
enum TerminalDrawerMetrics {
    /// The drawer's height until the user drags its handle (per window, `WindowModel.terminalHeight`).
    static let defaultHeight: CGFloat = 240
    /// A header and about five lines at 12 pt.
    static let minHeight: CGFloat = 130
    /// What the graph keeps above the drawer: its column titles and a few rows.
    static let graphMinHeight: CGFloat = 160
    /// Stacked with a pane open: what the graph, its divider and the bottom pane keep above the drawer.
    static let stackedPanesMinHeight = RepoLayoutMetrics.stackedGraphMin + RepoLayoutMetrics.gap
        + RepoLayoutMetrics.bottomPaneMin
    /// Stacked with a pane open, in a short window: the drawer gives way first, down to its header and a line (a
    /// merge banner at the 520 pt window minimum leaves it about 75).
    static let stackedMinHeight: CGFloat = 64
    /// The handle between the graph's card and the drawer: the panel's usual gap between cards.
    static let handleHeight: CGFloat = SectionCardMetrics.spacing
    /// Around the terminal's cells inside its card, below the header.
    static let contentPadding: CGFloat = 6

    /// `height` clamped so the drawer keeps its minimum and the graph keeps its own in `available` (the height the
    /// graph, the handle and the drawer share). When the panel is too short for both, the graph gives way.
    /// `stackedPaneOpen`: the drawer keeps room for Stacked's graph and bottom pane instead, and shrinks first.
    static func clamped(_ height: CGFloat, available: CGFloat, stackedPaneOpen: Bool = false) -> CGFloat {
        guard stackedPaneOpen else { return max(minHeight, min(height, available - graphMinHeight - handleHeight)) }
        return max(stackedMinHeight, min(height, available - stackedPanesMinHeight - handleHeight))
    }
}

/// A tab's terminal: one login shell in a pseudo-terminal and the view that shows it. Made by `RepoSession` on the
/// first open; started once the tab's profile is known (`start`), ended with the tab or the window (`end`). The view
/// moves between drawer hosts as the tab is shown again; it is never rebuilt.
@MainActor
final class RepoTerminal: NSObject {
    let view: BoldFilteringTerminalView
    /// Called once when the shell exits on its own (`exit`, ⌃D); not after `end()`.
    var onExit: () -> Void = {}
    /// Set by an open from the toolbar or ⌃`: the next time the view is in a window it takes the keyboard focus.
    var wantsFocus = false
    private var started = false
    private var ended = false
    /// The shell's pid while it runs, for `deinit`, which cannot reach the main-actor view: a session dropped without
    /// `end()` still hangs its shell up. 0 when there is none.
    nonisolated(unsafe) private var livePid: pid_t = 0
    /// The cursor style the preference asked for last: a change of another key leaves the cursor alone, so a program
    /// in the shell (vim, DECSCUSR) keeps the shape it set.
    private var appliedCursor: CursorStyle
    /// Watches `Preferences.defaults` to apply Settings › Terminal live; removed in `deinit` (`removeObserver` is
    /// thread-safe).
    nonisolated(unsafe) private var preferencesToken: NSObjectProtocol?

    override init() {
        let cursor = Self.preferredCursor()
        let options = TerminalOptions(
            termName: "xterm-256color", cursorStyle: cursor, scrollback: Self.preferredScrollback())
        appliedCursor = cursor
        // A first frame about the drawer's size, so the shell's first prompt is laid out for a real width; the drawer
        // resizes it (and the shell gets SIGWINCH) as soon as it is shown.
        view = BoldFilteringTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: TerminalDrawerMetrics.defaultHeight), font: Self.font(),
            options: options)
        view.keepsBold = Self.preferredBold()
        super.init()
        view.processDelegate = self
        view.nativeBackgroundColor = Palette.terminalBackground
        view.nativeForegroundColor = Palette.terminalForeground
        view.caretColor = Palette.terminalCaret
        view.selectedTextBackgroundColor = Palette.terminalSelection
        view.installColors(Palette.terminalANSI.map(Self.terminalColor))
        // Posted for every key; `applyPreferences` only touches what changed.
        preferencesToken = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: Preferences.defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPreferences() }
        }
    }

    deinit {
        if let preferencesToken { NotificationCenter.default.removeObserver(preferencesToken) }
        let pid = livePid
        guard pid > 0 else { return }
        kill(pid, SIGHUP)
        Self.reap(pid)
    }

    /// The shell's pid; 0 before `start` and after it ended.
    var shellPid: pid_t { livePid }

    /// Starts the login shell in `folder` with the user's environment and `profile`'s variables. Once.
    func start(in folder: URL, profile: Profile?) {
        guard !started, !ended else { return }
        started = true
        let shell = Self.loginShell()
        let environment = GitInvocation.terminalProcessEnvironment(
            base: ProcessInfo.processInfo.environment, profile: profile)
        // A "-" before argv[0]'s name is how login(1) and Terminal.app start a login shell: zsh, bash and fish
        // then read their profile files (path_helper's PATH, the user's exports).
        view.startProcess(
            executable: shell, args: [], environment: environment.map { "\($0.key)=\($0.value)" },
            execName: "-" + (shell as NSString).lastPathComponent, currentDirectory: folder.path)
        livePid = view.process.running ? view.process.shellPid : 0
    }

    /// Ends the shell: SIGHUP first (an interactive shell ignores SIGTERM, and a hangup is what a closed terminal
    /// window sends, so the shell passes it on to its jobs and saves its history), then SwiftTerm's `terminate()`
    /// (closes the pseudo-terminal, SIGTERM). SwiftTerm stops watching the process there, so it is reaped here.
    func end() {
        guard !ended else { return }
        ended = true
        let pid = livePid
        livePid = 0
        guard pid > 0 else { return }
        kill(pid, SIGHUP)
        view.terminate()
        Self.reap(pid)
    }

    /// Waits for `pid` off the main thread so it never stays a zombie: up to 2 s for the hangup, then SIGKILL.
    nonisolated private static func reap(_ pid: pid_t) {
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            for _ in 0..<40 {
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid || (result == -1 && errno == ECHILD) { return }
                usleep(50_000)
            }
            kill(pid, SIGKILL)
            _ = waitpid(pid, &status, 0)
        }
    }

    // MARK: Focus

    /// Gives the terminal the keyboard focus when an open asked for it and the view is in a window now, shown (a hidden
    /// tab's request waits).
    func focusIfRequested() {
        guard wantsFocus, let window = view.window, !view.isHiddenOrHasHiddenAncestor else { return }
        wantsFocus = false
        window.makeFirstResponder(view)
    }

    /// The drawer closes: the tab's own graph table (`graph`) gets the focus when the terminal had it (AppKit would
    /// leave it on the window, so the arrow keys would do nothing). A focused field elsewhere keeps it, and so does
    /// anything when the tab's graph is not shown in this window; a hidden tab's drawer leaves it alone. `repo` names
    /// the tab in the timing line.
    func returnFocusToGraph(_ graph: NSView?, repo: String) {
        guard let window = view.window, !view.isHiddenOrHasHiddenAncestor else { return }
        if let responder = window.firstResponder as? NSView, responder !== view, !responder.isDescendant(of: view) {
            return UITiming.focus(repo, "none")
        }
        guard let graph, graph.window === window, !graph.isHiddenOrHasHiddenAncestor else {
            return UITiming.focus(repo, "none")
        }
        window.makeFirstResponder(graph)
        UITiming.focus(repo, "graph")
    }

    // MARK: Shell and environment

    /// `PrefKey.terminalShell` when it names an executable, else the user's login shell (`userShell`).
    static func loginShell() -> String {
        let preferred = ((Preferences.defaults.string(forKey: PrefKey.terminalShell.rawValue) ?? "") as NSString)
            .expandingTildeInPath
        return isUsableShell(preferred) ? preferred : userShell()
    }

    /// `$SHELL`, else the passwd entry's shell, else zsh: Settings › Terminal's "Login shell".
    static func userShell() -> String {
        [ProcessInfo.processInfo.environment["SHELL"] ?? "", passwdShell() ?? ""].first(where: isUsableShell)
            ?? "/bin/zsh"
    }

    /// An absolute path to an executable file. Not a folder: `isExecutableFile` is also true for a folder one may
    /// enter.
    static func isUsableShell(_ path: String) -> Bool {
        var isFolder: ObjCBool = false
        return path.hasPrefix("/") && FileManager.default.fileExists(atPath: path, isDirectory: &isFolder)
            && !isFolder.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }

    private static func passwdShell() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        return String(cString: shell)
    }

    // MARK: Appearance

    /// Settings › Terminal changed a key: the font, the cursor and the scrollback follow at once (a new font resizes
    /// the grid and the shell gets SIGWINCH). Each only when its own value changed: setting the font clears the
    /// selection. Bold text applies to the output that comes next; what is on screen keeps its weight. The shell is
    /// never restarted; the shell setting applies to the next terminal.
    private func applyPreferences() {
        view.keepsBold = Self.preferredBold()
        let font = Self.font()
        if font.fontName != view.font.fontName || font.pointSize != view.font.pointSize { view.font = font }
        let terminal = view.getTerminal()
        let cursor = Self.preferredCursor()
        if cursor != appliedCursor {
            appliedCursor = cursor
            terminal.setCursorStyle(cursor)
        }
        let scrollback = Self.preferredScrollback()
        if scrollback != terminal.options.scrollback { terminal.changeScrollback(scrollback) }
    }

    /// `PrefKey.terminalFontName` at `terminalFontSize`; the system monospaced font (SF Mono) when the name is empty
    /// or not installed.
    private static func font() -> NSFont {
        let defaults = Preferences.defaults
        let stored = defaults.double(forKey: PrefKey.terminalFontSize.rawValue)
        let size = CGFloat(stored >= 6 && stored <= 72 ? stored : 12)
        let name = defaults.string(forKey: PrefKey.terminalFontName.rawValue) ?? ""
        if !name.isEmpty, let font = NSFont(name: name, size: size) { return font }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// `PrefKey.terminalCursor`: "block", "underline" or "bar", steady (no blinking redraws).
    private static func preferredCursor() -> CursorStyle {
        switch Preferences.defaults.string(forKey: PrefKey.terminalCursor.rawValue) {
        case "underline": .steadyUnderline
        case "bar": .steadyBar
        default: .steadyBlock
        }
    }

    /// `PrefKey.terminalBoldText`: output keeps its bold text.
    private static func preferredBold() -> Bool {
        Preferences.defaults.bool(forKey: PrefKey.terminalBoldText.rawValue)
    }

    /// `PrefKey.terminalScrollback`: the lines kept above the screen; 0 for a negative hand-written value.
    private static func preferredScrollback() -> Int {
        max(0, Preferences.defaults.integer(forKey: PrefKey.terminalScrollback.rawValue))
    }

    private static func terminalColor(_ color: NSColor) -> SwiftTerm.Color {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        func channel(_ value: CGFloat) -> UInt16 { UInt16((min(max(value, 0), 1) * 65535).rounded()) }
        return SwiftTerm.Color(
            red: channel(srgb.redComponent), green: channel(srgb.greenComponent), blue: channel(srgb.blueComponent))
    }

    #if DEBUG
    /// Types `text` into the shell, as keystrokes would (DEBUG seams).
    func type(_ text: String) {
        view.send(txt: text)
    }

    /// What the view shows now, read from the view and its terminal (DEBUG seams: Settings › Terminal applied live).
    func appearanceDescription() -> String {
        let terminal = view.getTerminal()
        return "font \(view.font.fontName) \(view.font.pointSize) cursor \(terminal.options.cursorStyle) "
            + "scrollback \(terminal.options.scrollback) cols \(terminal.cols) width \(Int(view.frame.width)) "
            + "optimal \(view.getOptimalFrameSize().width) scale \(view.window?.backingScaleFactor ?? 0)"
    }

    /// The screen's non-empty lines (DEBUG seams: shows the prompt where a screenshot cannot be taken).
    func screenLines() -> [String] {
        let text = String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self)
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    #endif
}

/// The terminal view, with Settings › Terminal "Bold text" off (`keepsBold` false) taking the bold attribute out of
/// the shell's output before SwiftTerm reads it, so bold text is drawn in the normal weight: SwiftTerm's bold font is
/// internal and cannot be replaced by the regular one.
final class BoldFilteringTerminalView: LocalProcessTerminalView {
    var keepsBold = false {
        didSet {
            // A sequence held back while filtering goes out as it came.
            guard keepsBold, !oldValue else { return }
            let pending = boldFilter.flush()
            if !pending.isEmpty { feed(byteArray: pending[...]) }
        }
    }

    private var boldFilter = SGRBoldFilter()

    /// The shell's output, on the main queue (`LocalProcess`'s default).
    override func dataReceived(slice: ArraySlice<UInt8>) {
        guard !keepsBold else { return super.dataReceived(slice: slice) }
        let filtered = boldFilter.filter(slice)
        if !filtered.isEmpty { super.dataReceived(slice: filtered[...]) }
    }
}

extension RepoTerminal: @preconcurrency LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    /// The shell exited on its own (SwiftTerm reaped it); never called after `end()`, which stops the watch.
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard !ended else { return }
        ended = true
        livePid = 0
        onExit()
    }
}

// MARK: - The drawer

/// The terminal drawer under the graph, inside panel 2's container: a drag handle (the gap above it) and the terminal
/// in its own card, with a header (title, folder, close). Its height is the window's (`WindowModel.terminalHeight`),
/// clamped to `available`, the height of the graph and the drawer together. Without a `terminal` (a drawer shown with
/// a new tab) the card shows a placeholder until the user clicks into it, which starts the shell.
struct TerminalDrawer: View {
    let session: RepoSession
    let terminal: RepoTerminal?
    let available: CGFloat
    /// Stacked shows a pane under the graph: the drawer shrinks first (`TerminalDrawerMetrics.clamped`).
    var stackedPaneOpen = false
    @Environment(WindowModel.self) private var model
    /// The height while the handle is dragged; written to the model when the drag ends.
    @State private var dragHeight: CGFloat?
    @State private var dragStart: CGFloat?

    var body: some View {
        let height = TerminalDrawerMetrics.clamped(
            dragHeight ?? model.terminalHeight, available: available, stackedPaneOpen: stackedPaneOpen)
        VStack(spacing: 0) {
            handle(height: height)
            SectionCard("Terminal", systemImage: "terminal", contentPadding: TerminalDrawerMetrics.contentPadding) {
                if let terminal {
                    TerminalHost(terminal: terminal)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    placeholder
                }
            } accessory: {
                HStack(spacing: 8) {
                    Text(session.url.lastPathComponent)
                        .font(.settingsCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        session.closeTerminal()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(RowIconButtonStyle())
                    .help(terminal == nil
                        ? "Hide the terminal" : "Hide the terminal (⌃`); it keeps running until the tab closes")
                    .accessibilityLabel("Hide the terminal")
                }
            }
            .frame(height: height)
        }
    }

    /// A pending drawer's content: no shell runs yet. A click anywhere in it, or its Start button, starts the shell
    /// as an explicit open does (with the keyboard focus).
    private var placeholder: some View {
        VStack(spacing: 10) {
            Text("Click to start the shell in \(session.url.lastPathComponent)")
                .font(.settingsCaption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Start") {
                session.openTerminal()
            }
            .buttonStyle(RowTextButtonStyle(prominent: true))
            .help("Start the shell in this repository (⌃`)")
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { session.openTerminal() }
    }

    /// The gap above the card: drag it to resize the drawer.
    private func handle(height: CGFloat) -> some View {
        Color.clear
            .frame(height: TerminalDrawerMetrics.handleHeight)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .pointerStyle(.rowResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = dragStart ?? height
                        if dragStart == nil { dragStart = height }
                        // Up makes it taller.
                        dragHeight = TerminalDrawerMetrics.clamped(
                            start - drag.translation.height, available: available, stackedPaneOpen: stackedPaneOpen)
                    }
                    .onEnded { _ in
                        if let dragHeight { model.terminalHeight = dragHeight }
                        dragHeight = nil
                        dragStart = nil
                    })
            .accessibilityHidden(true)
    }
}

/// Hosts the tab's terminal view in a container made for this drawer. The view itself belongs to the `RepoTerminal`:
/// taking the drawer down only detaches it.
private struct TerminalHost: NSViewRepresentable {
    let terminal: RepoTerminal
    @Environment(\.tabIsShown) private var tabIsShown

    func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView()
        container.isHidden = !tabIsShown
        container.attach(terminal)
        return container
    }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        if container.isHidden == tabIsShown { container.isHidden = !tabIsShown }
        if terminal.view.superview !== container { container.attach(terminal) }
    }

    static func dismantleNSView(_ container: TerminalContainerView, coordinator: ()) {
        container.detach()
    }
}

private final class TerminalContainerView: NSView {
    private weak var terminal: RepoTerminal?

    func attach(_ terminal: RepoTerminal) {
        self.terminal = terminal
        let view = terminal.view
        // A host of the same tab that is not dismantled yet may still hold it.
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        if window != nil { terminal.focusIfRequested() }
    }

    func detach() {
        guard let view = terminal?.view, view.superview === self else { return }
        view.removeFromSuperview()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // Next turn: SwiftUI is still installing the drawer in this one.
        DispatchQueue.main.async { [weak self] in self?.terminal?.focusIfRequested() }
    }
}
