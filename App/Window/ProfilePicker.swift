// The toolbar's profile chip, after the branch menu: the selected tab's profile name with its color dot, and the menu
// that switches the tab to another profile. The chip is a native `NSMenuToolbarItem` of `HeaderToolbar` (never a
// SwiftUI `.toolbar`); this file holds what it shows and what its menu lists.
import AppKit
import HistqCore
import SwiftUI

@MainActor
enum ProfilePicker {
    /// What the chip and the menu call "no profile": git then uses the user's own config.
    static let noneTitle = "No Profile"

    /// The chip's title: the profile's name, or `noneTitle`.
    static func title(_ profile: Profile?) -> String {
        guard let profile else { return noneTitle }
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Unnamed Profile" : name
    }

    /// The chip's tooltip: who the tab's commits are made as.
    static func toolTip(_ profile: Profile?) -> String {
        guard let profile else { return "Commits use your own git config. Click to pick a profile." }
        let email = profile.identity.email.isEmpty ? "" : " <\(profile.identity.email)>"
        return "Commits in this tab are made as \(profile.identity.name)\(email). Click to switch profiles."
    }

    /// The menu's badge for a missing workspace profile.
    static func missingTitle(_ missing: RepoSession.MissingProfile) -> String {
        "Profile missing: \(missing.name)"
    }

    /// The chip's and the badge's tooltip for a missing workspace profile.
    static func missingToolTip(_ missing: RepoSession.MissingProfile) -> String {
        "This workspace tab's profile \(missing.name) is not in Settings › Profiles: commits and remote actions are "
            + "blocked until you \(missing.embedded == nil ? "pick" : "import or pick") a profile."
    }

    /// The warning triangle in the warning orange (as the toolbar's read-only workspace label), with `gap` of
    /// transparent space after it. Not a template image, so the toolbar and the menu keep its color.
    static func warning(gap: CGFloat = 0) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [Palette.graphLanes[1]]))
        let symbol = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage()
        let size = NSSize(width: symbol.size.width + gap, height: symbol.size.height)
        let image = NSImage(size: size, flipped: false) { _ in
            symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Profile missing"
        return image
    }

    /// A dot in the profile color (`#RRGGBB`), or a hollow ring for no profile, with `gap` of transparent space
    /// after it. Not a template image, so the toolbar keeps its color.
    static func dot(hex: String?, gap: CGFloat = 0) -> NSImage {
        let size = NSSize(width: 10 + gap, height: 10)
        let image = NSImage(size: size, flipped: false) { rect in
            let circle = NSRect(x: 0, y: 0, width: 10, height: 10).insetBy(dx: 1, dy: 1)
            if let hex {
                NSColor(ProfileColors.color(hex)).setFill()
                NSBezierPath(ovalIn: circle).fill()
            } else {
                // Drawn at display time, so the ring follows the appearance's secondary label color.
                let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 0.5, dy: 0.5))
                ring.lineWidth = 1
                NSColor.secondaryLabelColor.setStroke()
                ring.stroke()
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = hex == nil ? noneTitle : "Profile color"
        return image
    }

    /// The menu: "Profile missing: <name>" first when the tab's workspace profile is not on this Mac
    /// (`WindowModel.missingProfile(of:)`), with "Import <name>…" when the workspace file defines it (it opens the
    /// consent sheet, `ProfileImportSheet`), then every profile (the tab's checked), "None (your git config)", then
    /// "Edit Profiles…", which opens Settings › Profiles. A pick switches the tab at once (`WindowModel.setProfile`).
    /// Shown by the toolbar chip (the selected tab) and by a tab's right-click menu (that tab, selected or not).
    static func entries(tab id: WindowModel.Tab.ID, current: UUID?, model: WindowModel) -> [MenuEntry] {
        let library = ProfileLibrary.shared
        var entries: [MenuEntry] = []
        let missing = model.missingProfile(of: id)
        if let missing {
            entries = [.action(missingTitle(missing), enabled: false, toolTip: missingToolTip(missing),
                               image: warning()) {}]
            if let embedded = missing.embedded {
                // Opens the consent sheet; only its Import adds the profile.
                entries += [.action("Import \(missing.name)…", enabled: library.store != nil) { [weak model] in
                    model?.presentModal(.importProfiles([embedded]))
                }]
            }
            entries += [.separator]
        }
        switch library.state {
        case .loaded(let store):
            entries += store.profiles.map { profile in
                .action(title(profile), checked: profile.id == current, image: dot(hex: profile.color)) { [weak model] in
                    model?.setProfile(profile.id, of: id)
                }
            }
        case .failed:
            entries += [.action("Profiles could not be read", enabled: false) {}]
        case .idle, .loading:
            entries += [.action("Loading profiles…", enabled: false) {}]
        }
        entries += [
            .separator,
            .action("None (your git config)", checked: current == nil && missing == nil) { [weak model] in model?.setProfile(nil, of: id) },
            .separator,
            .action("Edit Profiles…") { [weak model] in model?.selectSettings(.profiles) },
        ]
        return entries
    }
}
