// App icons by name: an SF Symbol, or a Lucide icon of the asset catalog when the name starts with "lucide-" (a
// template vector image, 24 by 24 with a 2 pt stroke, tinted like a symbol).
import AppKit
import SwiftUI

/// `Image(systemName:)` for an SF Symbol; a Lucide icon `size` points square (its strokes span about 18 of its 24,
/// so 15 matches a symbol at the 13 pt body font).
struct IconImage: View {
    let name: String
    var size: CGFloat = 15

    init(_ name: String, size: CGFloat = 15) {
        self.name = name
        self.size = size
    }

    var body: some View {
        if name.hasPrefix("lucide-") {
            Image(name)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: name)
        }
    }
}

extension NSImage {
    /// A template image for `name` (an SF Symbol or a Lucide asset), a Lucide one `size` points square: a copy, so
    /// setting its size never resizes the catalog's shared instance.
    static func icon(_ name: String, accessibilityDescription: String?, size: CGFloat = 16) -> NSImage? {
        guard name.hasPrefix("lucide-") else {
            return NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)
        }
        guard let image = NSImage(named: name)?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}
