// The onboarding's card over the window: a scrim, a glass card sized to its step (title, progress dots, the step's body,
// which scrolls when the window is short) and a footer (Back, Skip onboarding, Skip this step, Next). Return = Next,
// ← / → = Back / Next and Esc = Skip this step, when no text field has the focus. Welcome, the tour's demo state and
// finish have their bodies here, the setup steps in `OnboardingSetupSteps`; the rest show a placeholder for now.
import AppKit
import SwiftUI

struct OnboardingCard: View {
    let model: OnboardingModel
    /// Settings or a modal shows above the card: it is disabled and its keys do nothing.
    var isCovered = false
    let onOpenSettings: () -> Void
    @FocusState private var focused: Bool

    private static let width: CGFloat = 640
    private static let bodyMinHeight: CGFloat = 240

    var body: some View {
        // Nothing while the tour's spotlight runs: the content stays sharp and clickable for the spotlight.
        if model.showsCard {
            ZStack {
                ModalScrim()
                card
                    .padding(ModalMetrics.margin)
            }
        }
    }

    private var card: some View {
        let step = model.current
        return PanelContainer(cornerRadius: ModalMetrics.cornerRadius) {
            VStack(alignment: .leading, spacing: PanelContainerMetrics.padding) {
                header(step)
                    .padding(.horizontal, ModalMetrics.bodyInset)
                // The card hugs its body (at least `bodyMinHeight`); a body taller than the window leaves scrolls
                // inside its card, so the header and the buttons stay in view.
                BodyFit(minHeight: Self.bodyMinHeight) {
                    ScrollView {
                        BodyFit(minHeight: Self.bodyMinHeight) {
                            stepBody(step)
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous))
                .modifier(GlassCard(cornerRadius: SettingsMetrics.cardRadius))
                    .padding(.horizontal, ModalMetrics.bodyInset)
                    // A new body per step, switched in the click's frame and faded in.
                    .id(step)
                    .transition(.opacity)
                footer(step)
            }
            .animation(Motion.standard, value: step)
        }
        .frame(width: Self.width)
        .shadow(color: Palette.cardShadow, radius: 16, y: 6)
        .disabled(isCovered)
        .focusable(!isCovered)
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: [.return, .leftArrow, .rightArrow], phases: .down) { press in handleKey(press.key) }
        .onExitCommand {
            // Skip this step; nothing on the last one (Done ends the onboarding there), nor while a text field has
            // the focus (Esc is its own).
            guard !isCovered, step != .finish, !(NSApp.keyWindow?.firstResponder is NSText) else { return }
            model.skipStep()
        }
        // The card is installed on this turn; it takes the focus on the next one, and again after a step change
        // (the focused view may have gone with the old body) or once what covered it closes.
        .onAppear { takeFocus() }
        .onChange(of: step) { takeFocus() }
        .onChange(of: isCovered) { _, covered in if !covered { takeFocus() } }
    }

    // MARK: Header and footer

    private func header(_ step: OnboardingModel.Step) -> some View {
        let steps = OnboardingModel.Step.allCases
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Array(steps.enumerated()), id: \.element) { position, item in
                    Capsule()
                        .fill(item == step ? AnyShapeStyle(Palette.primaryFill)
                              : position < model.index ? AnyShapeStyle(.secondary)
                              : AnyShapeStyle(Palette.switchOffFill))
                        .frame(width: item == step ? 18 : 6, height: 6)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \(model.index + 1) of \(steps.count)")
            Text(step.title)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
        }
        .padding(SettingsMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func footer(_ step: OnboardingModel.Step) -> some View {
        HStack(spacing: ModalFooterMetrics.spacing) {
            if model.index > 0 {
                Button("Back") { model.back() }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
            }
            Spacer(minLength: 0)
            if step != .finish {
                Button("Skip onboarding") { model.skipAll() }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
            }
            // Welcome and finish carry their own buttons in the body (Start; Open Settings / Done).
            if step != .welcome, step != .finish {
                Button("Skip this step") { model.skipStep() }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
                Button("Next") { model.next() }
                    .buttonStyle(Self.primary)
            }
        }
        .environment(\.isModalFooter, true)
        .padding(.horizontal, ModalFooterMetrics.trailingPadding)
        .padding(.vertical, ModalFooterMetrics.verticalPadding)
        .frame(height: ModalFooterMetrics.buttonHeight + 2 * ModalFooterMetrics.verticalPadding)
    }

    /// Next, Start and Done: the modals' primary button, a solid blue capsule with a white label (the footer's size
    /// under `isModalFooter`), blue in an inactive window too.
    private static var primary: RowTextButtonStyle { RowTextButtonStyle(formRow: true, prominent: true) }

    // MARK: Bodies

    @ViewBuilder
    private func stepBody(_ step: OnboardingModel.Step) -> some View {
        switch step {
        case .welcome: welcomeBody
        case .git: OnboardingGitStep(model: model)
        case .profile: OnboardingProfileStep(model: model)
        case .github: OnboardingGitHubStep(model: model)
        case .ai: OnboardingAIStep(model: model)
        case .tour: tourBody
        case .finish: finishBody
        default: comingBody(step)
        }
    }

    private var welcomeBody: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("A native macOS git client that drives the git you already have.")
                .font(.title3)
                .multilineTextAlignment(.center)
            Text("Set it up and take a short tour. Takes about 3 minutes.")
                .foregroundStyle(.secondary)
            Button("Start") { model.next() }
                .buttonStyle(Self.primary)
                .environment(\.isModalFooter, true)
                .padding(.top, 4)
        }
        .padding(SettingsMetrics.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var finishBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text("You can change all of this later in Settings (⌘,).")
            } icon: {
                IconImage("gearshape").foregroundStyle(.secondary)
            }
            Label {
                Text("Press ⌘K for the command palette: switch layout, row height, lane colors, avatars and more in a "
                    + "few keys.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                IconImage("command").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: ModalFooterMetrics.spacing) {
                Spacer(minLength: 0)
                Button("Open Settings", action: onOpenSettings)
                    .buttonStyle(RowTextButtonStyle(formRow: true))
                Button("Done") { model.finish() }
                    .buttonStyle(Self.primary)
            }
            .environment(\.isModalFooter, true)
        }
        .font(.body)
        .padding(SettingsMetrics.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The tour's intro until the spotlight starts: why it can't run, a spinner while git makes the demo and its tab
    /// opens, or git's error (Next then goes to the finish step).
    private var tourBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let note = model.tourNote {
                warning(note, systemImage: "exclamationmark.triangle")
            } else {
                switch model.demo {
                case .idle, .creating, .ready:
                    Text("We made a small demo repository to show you around: the tour points at each part of the "
                        + "window in turn. Nothing in it touches your own repositories.")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        DelayedSpinner(detail: "onboarding demo") { model.current == .tour }
                        Text(demoIsReady ? "Opening the demo…" : "Making the demo repository…")
                            .foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    warning("The demo repository could not be made, so the tour can't run. Next goes on.",
                         systemImage: "exclamationmark.triangle")
                    // git's own words, as plain text.
                    Text(verbatim: message)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(SettingsMetrics.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The demo is made and its tab opens under the card.
    private var demoIsReady: Bool {
        if case .ready = model.demo { true } else { false }
    }

    private func comingBody(_ step: OnboardingModel.Step) -> some View {
        VStack(spacing: 8) {
            Text("This step is coming in a later build.")
                .foregroundStyle(.secondary)
            Text("Press Next or skip it.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(SettingsMetrics.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func warning(_ text: String, systemImage: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            IconImage(systemImage).foregroundStyle(Palette.conflictTone)
        }
    }

    // MARK: Keys and focus

    /// Return = Next, ← / → = Back / Next; nothing while covered or while a text field has the focus (its own
    /// Return and arrows), and → does nothing on the last step (Return is Done there).
    private func handleKey(_ key: KeyEquivalent) -> KeyPress.Result {
        guard !isCovered, !(NSApp.keyWindow?.firstResponder is NSText) else { return .ignored }
        switch key {
        case .return: model.next()
        case .leftArrow: model.back()
        case .rightArrow:
            guard model.current != .finish else { return .ignored }
            model.next()
        default: return .ignored
        }
        return .handled
    }

    private func takeFocus() {
        DispatchQueue.main.async {
            guard !isCovered, !(NSApp.keyWindow?.firstResponder is NSText) else { return }
            focused = true
        }
    }
}

/// The step's body: its content's ideal height, at least `minHeight`, at most the height proposed, with the content
/// placed in that whole height (a short body's spacer pushes its buttons down; `maxHeight: .infinity` centers it).
/// Around the body's `ScrollView` it hugs the content and caps it to the window; inside it (no height proposed) it
/// stretches a short body to `minHeight`.
private struct BodyFit: Layout {
    let minHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let ideal = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        // Rounded up: a fractional height left the scroll view a hair shorter than its content, so it scrolled.
        let height = max(ideal.height.rounded(.up), minHeight)
        return CGSize(width: proposal.width ?? ideal.width, height: min(height, proposal.height ?? height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

private extension OnboardingModel.Step {
    /// The card's title for this step.
    var title: String {
        switch self {
        case .welcome: "Welcome to Histq"
        case .git: "Git"
        case .profile: "Your profile"
        case .github: "GitHub"
        case .ai: "AI features"
        case .tabPosition: "Tab position"
        case .layout: "Layout"
        case .avatars: "Commit avatars"
        case .rowHeight: "Row height"
        case .laneColors: "Lane colors"
        case .fadeWorktrees: "Other worktrees"
        case .tour: "A quick tour"
        case .finish: "You're all set"
        }
    }
}
