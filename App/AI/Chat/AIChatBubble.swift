// The AI chat's floating bubble (ported from Dblore's `AIBubbleOverlay` and `AIBubbleLayout`): the app logo on the
// bottom edge of the graph column, dragged sideways to move it (a move under 4 pt is a click, which opens or closes the
// card), and the chat card above it, centered on the logo, kept between the margins and resized from its leading,
// trailing and top edges. The logo's place and the card's size are shared by all tabs and saved only when a drag ends.
// Only the logo and the card take clicks: the empty space passes them to the graph underneath.
import SwiftUI

struct AIChatBubble: View {
    @Bindable var model: AIChatModel
    /// The logo shows (false while something covers the graph column's bottom edge); the card still opens from the
    /// header button and Explain.
    var showsLogo = true
    /// Opens Settings › AI (`WindowModel.selectSettings(.ai)`).
    let onOpenSettings: () -> Void

    @AppStorage(PrefKey.aiChatBubblePosition.rawValue, store: Preferences.defaults) private var position = 1.0
    @AppStorage(PrefKey.aiChatCardWidth.rawValue, store: Preferences.defaults) private var savedWidth = 0.0
    @AppStorage(PrefKey.aiChatCardHeight.rawValue, store: Preferences.defaults) private var savedHeight = 0.0
    /// The live sideways drag of the logo, saved to `position` when it ends.
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false
    @State private var isPressed = false
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

            ZStack(alignment: .topLeading) {
                // Always there, sized as the card, so the transition scales in the card's space.
                ZStack {
                    if model.isExpanded {
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

                if showsLogo {
                    logo(containerWidth: size.width)
                        .offset(x: centerX - Self.radius, y: centerY - Self.radius)
                }
            }
        }
        // A card closed mid-resize (Esc) never ends its drag: drop the live resize.
        .onChange(of: model.isExpanded) {
            widthDrag = 0
            heightDrag = 0
        }
        // A logo hidden mid-drag never ends its drag either.
        .onChange(of: showsLogo) {
            dragOffset = 0
            isDragging = false
            isPressed = false
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
        Image("histq-logo")
            .resizable()
            .interpolation(.high)
            .frame(width: AIChatBubbleLayout.logoSize, height: AIChatBubbleLayout.logoSize)
            .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
            .contentShape(Rectangle())
            .scaleEffect(isPressed && !reduceMotion ? 0.92 : 1)
            .animation(reduceMotion ? nil : Motion.press, value: isPressed)
            .gesture(dragGesture(containerWidth: containerWidth))
            .help("AI Chat")
            .accessibilityElement()
            .accessibilityLabel("AI Chat")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggle() }
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
