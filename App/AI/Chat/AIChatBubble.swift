// The AI chat's floating bubble (ported from Dblore's `AIBubbleOverlay` and `AIBubbleLayout`): the logo (a black
// and white sphere with the SF `sparkles`) on the bottom edge of the tab's panels (sidebar, graph and detail), dragged
// sideways to move it (a move under 4 pt is a click, which opens or closes the card), and the chat card above it,
// centered on the logo, kept between the margins and resized from its leading, trailing and top edges. The logo's
// place and the card's size are shared by all tabs and saved only when a drag ends. Only the logo and the card take
// clicks: the empty space passes them to the panels underneath. Hovering the logo shows an x badge that hides the
// bubble (logo and card) in every tab until the header's AI button or anything that opens the chat shows it again.
import SwiftUI

struct AIChatBubble: View {
    @Bindable var model: AIChatModel
    /// Opens Settings › AI (`WindowModel.selectSettings(.ai)`).
    let onOpenSettings: () -> Void

    @AppStorage(PrefKey.aiChatBubblePosition.rawValue, store: Preferences.defaults) private var position = 1.0
    @AppStorage(PrefKey.aiChatCardWidth.rawValue, store: Preferences.defaults) private var savedWidth = 0.0
    @AppStorage(PrefKey.aiChatCardHeight.rawValue, store: Preferences.defaults) private var savedHeight = 0.0
    /// The live sideways drag of the logo, saved to `position` when it ends.
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false
    @State private var isPressed = false
    @State private var isHovering = false
    /// The live resize (points added to the saved width / height), saved when the drag ends.
    @State private var widthDrag: CGFloat = 0
    @State private var heightDrag: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A move under this is a click, not a drag.
    private static let dragThreshold: CGFloat = 4
    private static let radius = AIChatBubbleLayout.logoSize / 2

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let centerX = logoCenterX(containerWidth: size.width)
            let centerY = size.height - AIChatBubbleLayout.margin - Self.radius
            let cardWidth = cardWidth(containerWidth: size.width)
            let cardHeight = cardHeight(containerHeight: size.height)
            let cardMinX = AIChatBubbleLayout.cardMinX(logoCenterX: centerX, cardWidth: cardWidth,
                                                       containerWidth: size.width)
            let cardTop = centerY - Self.radius - AIChatBubbleLayout.gap - cardHeight
            let hidden = AISetup.shared.chatBubbleHidden

            ZStack(alignment: .topLeading) {
                // Always there, sized as the card, so the transition scales in the card's space.
                ZStack {
                    if model.isExpanded && !hidden {
                        card(width: cardWidth, height: cardHeight, containerSize: size)
                            .transition(.scale(scale: 0.9, anchor: AIChatBubbleLayout.scaleAnchor(
                                logoCenterX: centerX, cardMinX: cardMinX, cardWidth: cardWidth,
                                cardHeight: cardHeight))
                                .combined(with: .opacity))
                    }
                }
                .frame(width: cardWidth, height: cardHeight)
                .offset(x: cardMinX, y: cardTop)
                // Every toggle animates, whoever flips `isExpanded` (the logo, the header button, Explain).
                .animation(.snappy(duration: 0.2), value: model.isExpanded)

                if !hidden {
                    logo(containerWidth: size.width)
                        .offset(x: centerX - Self.radius, y: centerY - Self.radius)
                        .transition(.opacity)
                }
            }
            .animation(.snappy(duration: 0.2), value: hidden)
        }
        // Mounted with the tab while AI features show: the menus' Explain reads `isReady` from this first key read.
        .onAppear { AISetup.shared.loadKeysIfNeeded() }
        // A card closed mid-resize (Esc) never ends its drag: drop the live resize.
        .onChange(of: model.isExpanded) {
            widthDrag = 0
            heightDrag = 0
        }
        // Hidden (here, in another tab or from the header): this tab's card closes too, and a logo removed under the
        // pointer or mid-drag never gets its hover exit or drag end.
        .onChange(of: AISetup.shared.chatBubbleHidden) { _, hidden in
            guard hidden else { return }
            model.isExpanded = false
            dragOffset = 0
            isDragging = false
            isPressed = false
            isHovering = false
        }
    }

    /// The saved place plus the live drag, kept in the logo's range.
    private func logoCenterX(containerWidth: CGFloat) -> CGFloat {
        let saved = AIChatBubbleLayout.logoCenterX(fraction: position, containerWidth: containerWidth)
        return AIChatBubbleLayout.logoCenterX(
            fraction: AIChatBubbleLayout.fraction(forCenterX: saved + dragOffset, containerWidth: containerWidth),
            containerWidth: containerWidth)
    }

    /// The saved width plus the live resize, kept in the container.
    private func cardWidth(containerWidth: CGFloat) -> CGFloat {
        let saved = AIChatBubbleLayout.cardWidth(preferred: savedWidth > 0 ? CGFloat(savedWidth) : nil,
                                                 containerWidth: containerWidth)
        guard widthDrag != 0 else { return saved }
        return AIChatBubbleLayout.cardWidth(preferred: saved + widthDrag, containerWidth: containerWidth)
    }

    /// The saved height plus the live resize, kept in the container.
    private func cardHeight(containerHeight: CGFloat) -> CGFloat {
        let saved = AIChatBubbleLayout.cardHeight(preferred: savedHeight > 0 ? CGFloat(savedHeight) : nil,
                                                  containerHeight: containerHeight)
        guard heightDrag != 0 else { return saved }
        return AIChatBubbleLayout.cardHeight(preferred: saved + heightDrag, containerHeight: containerHeight)
    }

    // MARK: Card

    private func card(width: CGFloat, height: CGFloat, containerSize: CGSize) -> some View {
        AIChatPanel(model: model, onOpenSettings: onOpenSettings)
            .frame(width: width, height: height)
            // One layer, so the shadow never shows through the translucent card.
            .compositingGroup()
            .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
            .onExitCommand { model.isExpanded = false }
            .overlay(alignment: .leading) { resizeHandle(.leading, containerSize: containerSize).offset(x: -4) }
            .overlay(alignment: .trailing) { resizeHandle(.trailing, containerSize: containerSize).offset(x: 4) }
            .overlay(alignment: .top) { resizeHandle(.top, containerSize: containerSize).offset(y: -4) }
    }

    /// An invisible 8 pt strip on an edge. The card stays centered on the logo, so a side drag of d changes the width
    /// by 2d (the dragged edge follows the pointer unless the card is pinned to a margin); the top drag changes the
    /// height, the bottom staying above the logo. A double click resets that size to its default.
    private func resizeHandle(_ edge: Edge, containerSize: CGSize) -> some View {
        let isTop = edge == .top
        return Color.clear
            .frame(width: isTop ? nil : 8, height: isTop ? 8 : nil)
            .contentShape(Rectangle())
            .pointerStyle(isTop ? .rowResize : .columnResize)
            .onTapGesture(count: 2) {
                withTransaction(Transaction(animation: nil)) {
                    if isTop { savedHeight = 0 } else { savedWidth = 0 }
                }
            }
            .gesture(resizeGesture(edge, containerSize: containerSize))
    }

    private func resizeGesture(_ edge: Edge, containerSize: CGSize) -> some Gesture {
        // Global space: the handle moves with the card while it resizes.
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                withTransaction(Transaction(animation: nil)) {
                    switch edge {
                    case .top: heightDrag = -value.translation.height
                    case .leading: widthDrag = -2 * value.translation.width
                    default: widthDrag = 2 * value.translation.width
                    }
                }
            }
            .onEnded { _ in
                withTransaction(Transaction(animation: nil)) {
                    if edge == .top {
                        savedHeight = Double(cardHeight(containerHeight: containerSize.height))
                        heightDrag = 0
                    } else {
                        savedWidth = Double(cardWidth(containerWidth: containerSize.width))
                        widthDrag = 0
                    }
                }
            }
    }

    // MARK: Logo

    private func logo(containerWidth: CGFloat) -> some View {
        orb
            .contentShape(Circle())
            .scaleEffect(isPressed && !reduceMotion ? 0.92 : 1)
            .animation(reduceMotion ? nil : Motion.press, value: isPressed)
            .gesture(dragGesture(containerWidth: containerWidth))
            .help("AI Chat")
            .accessibilityElement()
            .accessibilityLabel("AI Chat")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggle() }
            // After the gesture, so the badge takes its own clicks; the hover covers the badge too.
            .overlay(alignment: .topTrailing) { hideBadge }
            .onHover { isHovering = $0 }
    }

    /// The SF `sparkles` on a black and white sphere: a radial body lit from the top left (graphite while the card is
    /// closed, a lighter grey while it is open, cross-faded), a glossy highlight on top, a lighter rim above and a
    /// darker one below, and soft shadows underneath.
    private var orb: some View {
        let size = AIChatBubbleLayout.logoSize
        return ZStack {
            orbBody(highlight: 0.42, middle: 0.17, edge: 0.04, size: size)
            orbBody(highlight: 0.78, middle: 0.46, edge: 0.18, size: size)
                .opacity(model.isExpanded ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: model.isExpanded)
            Ellipse()
                .fill(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.62, height: size * 0.38)
                .offset(y: -size * 0.24)
            Circle()
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .black.opacity(0.3)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1)
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 1.5, y: 1)
        }
        .frame(width: size, height: size)
        .compositingGroup()
        .shadow(color: .black.opacity(0.45), radius: 8, y: 4)
        .shadow(color: .black.opacity(0.4), radius: 2.5, y: 2)
    }

    /// The sphere's body in greys: `highlight` at the lit top left, `middle`, then `edge` at the far rim.
    private func orbBody(highlight: Double, middle: Double, edge: Double, size: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [Color(white: highlight), Color(white: middle), Color(white: edge)],
                                 center: UnitPoint(x: 0.32, y: 0.26), startRadius: 0, endRadius: size * 0.85))
    }

    private var showsHideBadge: Bool {
        #if DEBUG
        // `-HistqAI hide-badge` (stub runs only): shown without a hover, for a background shot.
        if AIStub.seamHook == "hide-badge" { return !isDragging }
        #endif
        return isHovering && !isDragging
    }

    /// The x on the logo's corner while the pointer is over it (not while dragging): hides the bubble in every tab.
    private var hideBadge: some View {
        let visible = showsHideBadge
        return Button {
            model.isExpanded = false
            AISetup.shared.setChatBubbleHidden(true)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Palette.surface))
                .overlay(Circle().strokeBorder(Palette.sheetCardBorder, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Hide AI bubble")
        .accessibilityLabel("Hide AI bubble")
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .animation(.easeOut(duration: 0.15), value: visible)
    }

    private func dragGesture(containerWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                isPressed = true
                let distance = hypot(value.translation.width, value.translation.height)
                guard isDragging || distance >= Self.dragThreshold else { return }
                withTransaction(Transaction(animation: nil)) {
                    isDragging = true
                    dragOffset = value.translation.width
                }
            }
            .onEnded { _ in
                isPressed = false
                guard isDragging else {
                    toggle()
                    return
                }
                withTransaction(Transaction(animation: nil)) {
                    position = AIChatBubbleLayout.fraction(forCenterX: logoCenterX(containerWidth: containerWidth),
                                                           containerWidth: containerWidth)
                    dragOffset = 0
                    isDragging = false
                }
            }
    }

    private func toggle() {
        model.isExpanded.toggle()
    }
}

/// The bubble's geometry: the logo's place along the bottom edge, the card's place above it, the card's size bounds
/// and the anchor its expand transition scales from.
private enum AIChatBubbleLayout {
    static let logoSize: CGFloat = 40
    static let margin: CGFloat = 12
    static let gap: CGFloat = 8
    static let minCardWidth: CGFloat = 320
    static let defaultCardWidth: CGFloat = 400
    static let maxCardWidth: CGFloat = 720
    static let minCardHeight: CGFloat = 360
    static let maxCardHeight: CGFloat = 640

    private static var radius: CGFloat { logoSize / 2 }

    private static func centerRange(containerWidth: CGFloat) -> (min: CGFloat, max: CGFloat) {
        (margin + radius, containerWidth - margin - radius)
    }

    /// The logo's center x for a 0...1 fraction; a fraction out of range is clamped.
    static func logoCenterX(fraction: Double, containerWidth: CGFloat) -> CGFloat {
        let range = centerRange(containerWidth: containerWidth)
        return range.min + CGFloat(min(max(fraction, 0), 1)) * (range.max - range.min)
    }

    /// The 0...1 fraction of a logo center x; 0 when the range is empty.
    static func fraction(forCenterX centerX: CGFloat, containerWidth: CGFloat) -> Double {
        let range = centerRange(containerWidth: containerWidth)
        let span = range.max - range.min
        guard span > 0 else { return 0 }
        return Double(min(max((centerX - range.min) / span, 0), 1))
    }

    /// The preferred width (nil = the default) kept in min...max, then capped to fit between the margins. Never
    /// negative.
    static func cardWidth(preferred: CGFloat?, containerWidth: CGFloat) -> CGFloat {
        let upper = min(maxCardWidth, containerWidth - 2 * margin)
        return max(min(max(preferred ?? defaultCardWidth, minCardWidth), upper), 0)
    }

    /// The card's leading x: centered on the logo, kept between the margins; at the leading margin when the container
    /// is narrower than the card and both margins.
    static func cardMinX(logoCenterX: CGFloat, cardWidth: CGFloat, containerWidth: CGFloat) -> CGFloat {
        let maxX = containerWidth - margin - cardWidth
        guard maxX >= margin else { return margin }
        return min(max(logoCenterX - cardWidth / 2, margin), maxX)
    }

    /// The preferred height (nil = 75% of the container, kept in min...max), at least the minimum, then capped so the
    /// card fits above the logo with a margin on top. Never negative.
    static func cardHeight(preferred: CGFloat?, containerHeight: CGFloat) -> CGFloat {
        let height = preferred.map { max($0, minCardHeight) }
            ?? min(max(containerHeight * 0.75, minCardHeight), maxCardHeight)
        let cap = containerHeight - logoSize - 2 * margin - gap
        return max(min(height, cap), 0)
    }

    /// The scale anchor, in the card's unit space, at the logo's center under the card.
    static func scaleAnchor(logoCenterX: CGFloat, cardMinX: CGFloat, cardWidth: CGFloat,
                            cardHeight: CGFloat) -> UnitPoint {
        let x = cardWidth > 0 ? (logoCenterX - cardMinX) / cardWidth : 0.5
        let y = cardHeight > 0 ? (cardHeight + gap + radius) / cardHeight : 1
        return UnitPoint(x: x, y: y)
    }
}
