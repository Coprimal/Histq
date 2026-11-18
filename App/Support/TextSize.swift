// The app-wide text size (`PrefKey.textSize`) of the graph, the sidebar and the file lists. macOS text styles do not
// follow `dynamicTypeSize`, so those views take these explicit fonts instead of `.body` and `.settingsCaption`.
// Regular gives the sizes the app had before the setting existed.
import AppKit
import SwiftUI

/// Small, Regular (the default) or Large. Body text is 12 / 13 / 15 pt; every other size scales with it (`scaled`).
enum TextSize: String, CaseIterable, Sendable {
    case small, regular, large

    /// The size for the preference stored now; anything unknown reads as regular.
    static var current: TextSize {
        TextSize(rawValue: Preferences.defaults.string(forKey: PrefKey.textSize.rawValue) ?? "") ?? .regular
    }

    /// Body text in points. Regular's 13 is SwiftUI's `.body` on macOS and the graph's ref badges.
    var bodySize: CGFloat {
        switch self {
        case .small: 12
        case .regular: 13
        case .large: 15
        }
    }

    /// A size the app uses at Regular (`points`), scaled with the body text and rounded to the half point: the same
    /// at Regular, so 11 gives 10 / 11 / 12.5.
    func scaled(_ points: CGFloat) -> CGFloat {
        self == .regular ? points : (points * bodySize / 13 * 2).rounded() / 2
    }

    /// Captions and counts in points: 11 at Regular, `.settingsCaption` (`.subheadline`) and the graph's ref counts.
    var captionSize: CGFloat { scaled(11) }

    /// One line of body text in points, for row heights: 15 / 16 / 18.
    var lineHeight: CGFloat { fonts.lineHeight }

    /// Body text.
    var body: Font { fonts.body }
    var bodyMedium: Font { fonts.bodyMedium }
    /// Card titles.
    var bodySemibold: Font { fonts.bodySemibold }
    /// Captions; a count adds `.monospacedDigit()`.
    var caption: Font { fonts.caption }

    /// The AppKit fonts, for the graph's cells.
    var bodyNSFont: NSFont { fonts.bodyNS }
    var captionNSFont: NSFont { fonts.captionNS }
    /// Counts: the caption with digits of the same width.
    var countNSFont: NSFont { fonts.countNS }

    private var fonts: Fonts {
        switch self {
        case .small: Self.smallFonts
        case .regular: Self.regularFonts
        case .large: Self.largeFonts
        }
    }

    /// Built once per size, so no row allocates a font. NSFont is immutable and thread-safe, so the
    /// `nonisolated(unsafe)` only covers a missing Sendable mark.
    private struct Fonts {
        let body: Font
        let bodyMedium: Font
        let bodySemibold: Font
        let caption: Font
        let bodyNS: NSFont
        let captionNS: NSFont
        let countNS: NSFont
        let lineHeight: CGFloat

        init(_ size: TextSize) {
            body = .system(size: size.bodySize)
            // Regular keeps the weighted text styles and the caption the views had: a weighted `.system(size: 13)`
            // draws a hair off `.body.weight(_:)` (the plain one matches a Text's default font, an explicit `.body`
            // does not).
            let regular = size == .regular
            bodyMedium = regular ? .body.weight(.medium) : .system(size: size.bodySize, weight: .medium)
            bodySemibold = regular ? .body.weight(.semibold) : .system(size: size.bodySize, weight: .semibold)
            caption = regular ? .settingsCaption : .system(size: size.captionSize)
            bodyNS = .systemFont(ofSize: size.bodySize)
            captionNS = .systemFont(ofSize: size.captionSize)
            countNS = .monospacedDigitSystemFont(ofSize: size.captionSize, weight: .regular)
            lineHeight = ceil(bodyNS.ascender - bodyNS.descender + bodyNS.leading)
        }
    }

    nonisolated(unsafe) private static let smallFonts = Fonts(.small)
    nonisolated(unsafe) private static let regularFonts = Fonts(.regular)
    nonisolated(unsafe) private static let largeFonts = Fonts(.large)
}

extension EnvironmentValues {
    /// The repo layout's text size (`PrefKey.textSize`), set where the layout reads the preference.
    @Entry var textSize = TextSize.regular
}
