using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Histq.App.Shell.Dialogs;

/// <summary>A window shows one ContentDialog at a time: every dialog of the app takes this gate first.</summary>
internal static class DialogGate
{
    private static bool _showing;

    /// <summary>True, and the gate is held, when no dialog is up; release it with <see cref="Exit"/>.</summary>
    public static bool TryEnter()
    {
        if (_showing)
            return false;
        _showing = true;
        return true;
    }

    public static void Exit() => _showing = false;
}

/// <summary>
/// A destructive action's confirmation (the Mac's ModalConfirmation): a title, one line, the action's button and
/// Cancel, which is the default (Enter and Esc both keep things as they are). Texts are shown as given: callers pass
/// sanitized names.
/// </summary>
internal static class ConfirmDialog
{
    /// <summary>True when the user picks <paramref name="button"/>; false when cancelled or while another dialog is up.
    /// </summary>
    public static async Task<bool> AskAsync(XamlRoot root, string title, string message, string button)
    {
        if (!DialogGate.TryEnter())
            return false;
        try
        {
            var dialog = new ContentDialog
            {
                XamlRoot = root,
                Title = title,
                Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
                PrimaryButtonText = button,
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Close,
            };
            if (Application.Current.Resources.TryGetValue("DefaultContentDialogStyle", out object? style)
                && style is Style dialogStyle)
                dialog.Style = dialogStyle;
            return await dialog.ShowAsync() == ContentDialogResult.Primary;
        }
        finally
        {
            DialogGate.Exit();
        }
    }
}
