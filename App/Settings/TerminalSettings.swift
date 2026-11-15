// Settings › Terminal (task 13.2): the integrated terminal's font, cursor, scrollback, bold text and shell, and whether
// a new repo tab opens it. Each change is saved at once in `Preferences.defaults`. Open terminals apply the font,
// cursor, scrollback and bold text at once (`RepoTerminal` watches the keys; bold text for the output that comes next);
// the shell only applies to terminals started afterwards.
import CoreText
import SwiftUI

struct TerminalSettings: View {
    @AppStorage(PrefKey.terminalFontName.rawValue, store: Preferences.defaults) private var fontName = ""
    @AppStorage(PrefKey.terminalFontSize.rawValue, store: Preferences.defaults) private var fontSize = 12.0
    @AppStorage(PrefKey.terminalCursor.rawValue, store: Preferences.defaults) private var cursor = "block"
    @AppStorage(PrefKey.terminalScrollback.rawValue, store: Preferences.defaults) private var scrollback = 10_000
    @AppStorage(PrefKey.terminalBoldText.rawValue, store: Preferences.defaults) private var boldText = false
    @AppStorage(PrefKey.terminalShell.rawValue, store: Preferences.defaults) private var shell = ""
    @AppStorage(PrefKey.terminalOpenWithNewTab.rawValue, store: Preferences.defaults) private var openWithNewTab = false
    /// The installed monospaced fonts, listed off the main thread; `.loading` shows a skeleton in the font row.
    @State private var fonts: Loadable<[MonospacedFont]> = .idle
    /// "Custom" picked while no custom shell is saved yet: the path row shows, the login shell is still used.
    @State private var customPicked = false
    @State private var shellDraft = ""
    /// Why the last custom path was refused (not saved).
    @State private var shellError: String?

    private static let offeredSizes = Array(10...20).map(Double.init)
    private static let offeredScrollbacks = [1_000, 5_000, 10_000, 50_000]

    var body: some View {
        SettingsPageGate(section: .terminal, isLoaded: true) {
            SettingsGroup("Display", description: "Open terminals change at once.") {
                fontRow
                SettingsDivider()
                LabeledContent {
                    CapsuleMenuPicker(label: "Size", selection: $fontSize, title: Text(Self.sizeTitle(fontSize))) {
                        ForEach(sizes, id: \.self) { size in
                            Text(Self.sizeTitle(size)).tag(size)
                        }
                    }
                } label: {
                    Text("Font size")
                }
                SettingsDivider()
                LabeledContent {
                    CapsuleTabs(selection: $cursor, tabs: ["block", "underline", "bar"],
                                title: { Text($0.capitalized) }, compact: true)
                        .fixedSize()
                } label: {
                    Text("Cursor")
                    SettingsHint("A program in the shell (vim) may set its own until this changes.")
                }
                SettingsDivider()
                LabeledContent {
                    CapsuleTabs(selection: $scrollback, tabs: scrollbacks, title: { Text($0.formatted()) },
                                compact: true)
                        .fixedSize()
                } label: {
                    Text("Scrollback")
                    SettingsHint("Lines kept above the screen. A smaller value drops the oldest at once.")
                }
                SettingsDivider()
                SettingsSwitchRow(title: "Bold text",
                                  hint: "Off shows bold output in the normal weight. Text already on screen keeps "
                                      + "its weight.",
                                  isOn: $boldText)
            }
            shellGroup
            SettingsGroup("New tabs") {
                SettingsSwitchRow(title: "Open terminal with each new tab",
                                  hint: "Opens the drawer for each new tab; the shell starts when you click into "
                                      + "it, because shell prompts run git in the repository. Tabs restored at "
                                      + "launch keep theirs closed.",
                                  isOn: $openWithNewTab)
            }
        } skeleton: {
            EmptyView()
        }
        .task {
            guard case .idle = fonts else { return }
            fonts = .loading
            fonts = .loaded(await Self.monospacedFonts())
        }
    }

    /// The offered sizes, plus a size set by hand (`defaults write`).
    private var sizes: [Double] {
        Self.offeredSizes.contains(fontSize) ? Self.offeredSizes : (Self.offeredSizes + [fontSize]).sorted()
    }

    /// The offered line counts, plus a count set by hand.
    private var scrollbacks: [Int] {
        Self.offeredScrollbacks.contains(scrollback)
            ? Self.offeredScrollbacks : (Self.offeredScrollbacks + [scrollback]).sorted()
    }

    private static func sizeTitle(_ size: Double) -> String {
        "\(size.formatted(.number.precision(.fractionLength(0...1)))) pt"
    }

    // MARK: Font

    /// "" is the system monospaced font (SF Mono, which is not an installed family); a name not installed (any more)
    /// is listed too, under its own name, and the terminal draws SF Mono for it.
    @ViewBuilder
    private var fontRow: some View {
        LabeledContent {
            switch fonts {
            case .loaded(let installed):
                let choices = installed.contains { $0.name == fontName } || fontName.isEmpty
                    ? installed : installed + [MonospacedFont(name: fontName, family: fontName)]
                CapsuleMenuPicker(label: "Font", selection: $fontName,
                                  title: Text(choices.first { $0.name == fontName }?.family ?? Self.systemTitle)) {
                    Text(Self.systemTitle).tag("")
                    Divider()
                    ForEach(choices) { font in
                        Text(font.family).tag(font.name)
                    }
                }
            case .idle, .loading, .failed:
                SkeletonLine(width: 120, height: 20)
            }
        } label: {
            Text("Font")
            SettingsHint("The monospaced fonts installed on this Mac.")
        }
    }

    private static let systemTitle = "SF Mono (system)"

    /// The installed monospaced families, by name, each as its regular face's PostScript name (what `NSFont(name:)`
    /// takes). CoreText, which is thread-safe, so the list never holds the page's first frame.
    @concurrent
    private nonisolated static func monospacedFonts() async -> [MonospacedFont] {
        let traits = [kCTFontSymbolicTrait: CTFontSymbolicTraits.traitMonoSpace.rawValue] as CFDictionary
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontTraitsAttribute: traits] as CFDictionary)
        let collection = CTFontCollectionCreateWithFontDescriptors([descriptor] as CFArray, nil)
        let matches = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] ?? []
        var best: [String: (name: String, score: Int)] = [:]
        for match in matches {
            guard let family = CTFontDescriptorCopyAttribute(match, kCTFontFamilyNameAttribute) as? String,
                  let name = CTFontDescriptorCopyAttribute(match, kCTFontNameAttribute) as? String,
                  // Hidden system faces (".SF NS Mono") are not meant to be picked by name.
                  !family.hasPrefix("."), !name.hasPrefix(".")
            else { continue }
            let score = faceScore(match)
            if let current = best[family], current.score >= score { continue }
            best[family] = (name, score)
        }
        return best.map { MonospacedFont(name: $0.value.name, family: $0.key) }
            .filter { CTFontCopyPostScriptName(CTFontCreateWithName($0.name as CFString, 12, nil)) as String == $0.name }
            .sorted { $0.family.localizedStandardCompare($1.family) == .orderedAscending }
    }

    /// The face a family is shown with: "Regular", else an upright face that is not bold, else any.
    private nonisolated static func faceScore(_ face: CTFontDescriptor) -> Int {
        if CTFontDescriptorCopyAttribute(face, kCTFontStyleNameAttribute) as? String == "Regular" { return 2 }
        let traits = CTFontDescriptorCopyAttribute(face, kCTFontTraitsAttribute) as? [CFString: Any]
        let symbolic = (traits?[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0
        let styled = CTFontSymbolicTraits.traitBold.rawValue | CTFontSymbolicTraits.traitItalic.rawValue
        return symbolic & styled == 0 ? 1 : 0
    }

    // MARK: Shell

    private var isCustom: Bool { !shell.isEmpty || customPicked }

    private var shellGroup: some View {
        SettingsGroup("Shell") {
            LabeledContent {
                CapsuleTabs(selection: Binding(get: { isCustom }, set: setCustom), tabs: [false, true],
                            title: { $0 ? Text("Custom") : Text("Login shell") }, compact: true)
                    .fixedSize()
            } label: {
                Text("Shell")
                SettingsHint("Login shell: \(ProfileLibrary.abbreviated(RepoTerminal.userShell())). New terminals "
                    + "use the change; a running shell keeps the one it started with.")
            }
            if isCustom {
                SettingsDivider()
                LabeledContent {
                    HStack(spacing: 8) {
                        TextField("Path", text: $shellDraft, prompt: Text("/opt/homebrew/bin/fish"))
                            .textFieldStyle(.settings)
                            .frame(maxWidth: 260)
                            .labelsHidden()
                            .onSubmit { useShell(at: shellDraft) }
                        Button("Choose…", action: chooseShell)
                            .buttonStyle(RowTextButtonStyle(formRow: true))
                    }
                } label: {
                    Text("Path")
                    if let shellError {
                        Text(shellError)
                            .font(.settingsCaption)
                            .foregroundStyle(.red)
                    } else {
                        SettingsHint("Press Return to use the path typed here. It starts as a login shell.")
                    }
                }
            }
        }
        .onAppear { shellDraft = shell }
    }

    private func setCustom(_ custom: Bool) {
        shellError = nil
        customPicked = custom
        // Back to the login shell: forget the custom path.
        if !custom { shell = "" }
    }

    private func chooseShell() {
        Task {
            guard let path = await ProfileLibrary.chooseFile(
                prompt: "Use This Shell", message: "Choose a shell for the terminal", startingAt: "/bin")
            else { return }
            shellDraft = path
            useShell(at: path)
        }
    }

    /// Saves `text` only when it is an absolute path to an executable file, so a typo never leaves new terminals on
    /// a shell that cannot start (`RepoTerminal.loginShell` would quietly fall back to the login shell).
    private func useShell(at text: String) {
        guard let path = ProfileLibrary.absolutePath(text) else {
            shellError = "Enter an absolute path."
            return
        }
        guard RepoTerminal.isUsableShell(path) else {
            shellError = "\(ProfileLibrary.abbreviated(path)) is not an executable file."
            return
        }
        shellError = nil
        shellDraft = path
        shell = path
    }
}

/// An installed monospaced family: its name in the menu, its regular face's PostScript name in the preference.
struct MonospacedFont: Identifiable, Hashable, Sendable {
    let name: String
    let family: String

    var id: String { name }
}
