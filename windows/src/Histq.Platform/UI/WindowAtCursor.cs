using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.UI.WindowsAndMessaging;

namespace Histq.Platform.UI;

/// <summary>The top-level window under the mouse pointer, as the system stacks them (a tab dragged out of its window
/// lands on the window it is released over).</summary>
public static class WindowAtCursor
{
    /// <summary>The handle of the top-level window under the pointer now; 0 when there is none or the pointer position
    /// cannot be read.</summary>
    public static nint Root()
    {
        if (!PInvoke.GetCursorPos(out var point))
            return 0;
        HWND hit = PInvoke.WindowFromPoint(point);
        if (hit.IsNull)
            return 0;
        HWND root = PInvoke.GetAncestor(hit, GET_ANCESTOR_FLAGS.GA_ROOT);
        return root.IsNull ? 0 : (nint)root;
    }
}
