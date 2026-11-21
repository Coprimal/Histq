// Whether a repo layout is the tab on screen. A kept-alive layout of a tab that is not shown stays mounted, hidden;
// SwiftUI's hit testing does not reach the AppKit views inside it, so they follow this flag themselves.
import SwiftUI

extension EnvironmentValues {
    /// False for a kept-alive tab layout that is not the shown tab. The AppKit representables inside it hide their
    /// NSView (`isHidden`), so it leaves its tracking areas, cursor rects, drag targets and the key view loop.
    @Entry var tabIsShown = true
}
