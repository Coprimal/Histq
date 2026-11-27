using Histq.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace Histq.App.Shell.Dialogs;

/// <summary>What Set Icon… decided.</summary>
/// <param name="Mark">The tab's new icon: an uploaded image's reference, an emoji, or null to remove it.</param>
internal sealed record TabIconChoice(string? Mark);

/// <summary>
/// A tab's menu › Set Icon… (TabEmojiModal, App/Window/ModalHost.swift at 6fa6d40): the tab's emoji in one field that
/// keeps only the last emoji typed or picked (<see cref="TabEmoji.Normalized"/>), a hint for the Win+. emoji panel (the
/// Mac's Choose… opens the Character Viewer), and the uploaded images under it (<see cref="IconLibraryPicker"/>); an
/// emoji clears the image and an image clears the emoji. Enter or Save keeps the image, else the emoji, else removes
/// the icon; Remove (shown when the tab has an icon) removes it.
/// </summary>
internal sealed partial class TabEmojiDialog : ContentDialog
{
    private readonly TextBox _field;
    private readonly IconLibraryPicker _picker;
    private TabIconChoice? _choice;

    /// <summary>The field's text is being set from code: its TextChanged does not normalize it again.</summary>
    private bool _settingText;

    private TabEmojiDialog(XamlRoot root, MainWindow window, string folder, string? mark)
    {
        string name = DisplayText.Sanitize(folder);
        XamlRoot = root;
        if (Application.Current.Resources.TryGetValue("DefaultContentDialogStyle", out object? style) && style is Style dialogStyle)
            Style = dialogStyle;
        Title = $"Set an icon for {(name.Length == 0 ? "this tab" : name)}";
        PrimaryButtonText = "Save";
        CloseButtonText = "Cancel";
        DefaultButton = ContentDialogButton.Primary;
        if (mark is not null)
            SecondaryButtonText = "Remove";

        // An image's reference goes to the picker, never into the field.
        bool isImage = CustomIcon.IsRef(mark);
        _field = new TextBox
        {
            PlaceholderText = "Emoji",
            Text = isImage || mark is null ? string.Empty : Shown(mark),
            IsSpellCheckEnabled = false,
            IsTextPredictionEnabled = false,
        };
        AutomationProperties.SetName(_field, "Emoji");
        _field.TextChanged += OnFieldTextChanged;
        _field.KeyDown += OnFieldKeyDown;

        _picker = new IconLibraryPicker();
        _picker.Attach(window);
        if (isImage)
            _picker.Selection = mark;
        _picker.SelectionChanged += (_, _) =>
        {
            if (_picker.Selection is not null)
                SetField(string.Empty);
        };

        var panel = new StackPanel { Spacing = 12, MinWidth = 360 };
        panel.Children.Add(new TextBlock
        {
            Text = "The tab shows this emoji or image at its left, and a pinned tab shows only it. Leave it empty for none.",
            TextWrapping = TextWrapping.Wrap,
        });
        panel.Children.Add(_field);
        panel.Children.Add(new TextBlock
        {
            Text = "Press Win+. (period) in the field to open the emoji panel.",
            TextWrapping = TextWrapping.Wrap,
            FontSize = 12,
            Opacity = 0.6,
        });
        panel.Children.Add(_picker);
        Content = panel;

        PrimaryButtonClick += (_, _) => _choice = Saved();
        SecondaryButtonClick += (_, _) => _choice = new TabIconChoice(null);
        Opened += (_, _) =>
        {
            _field.Focus(FocusState.Programmatic);
            _field.SelectAll();
        };
    }

    /// <summary>Asks for the icon of the tab whose folder is <paramref name="folder"/> (its current icon slot
    /// <paramref name="mark"/> filled in): the choice when saved or removed, null when cancelled or while another dialog
    /// is up. <paramref name="window"/> owns the file picker and shows the refused-image toasts.</summary>
    public static async Task<TabIconChoice?> AskAsync(XamlRoot root, MainWindow window, string folder, string? mark)
    {
        // A window shows one ContentDialog at a time.
        if (!DialogGate.TryEnter())
            return null;
        try
        {
            var dialog = new TabEmojiDialog(root, window, folder, mark);
            try
            {
                await dialog.ShowAsync();
                return dialog._choice;
            }
            finally
            {
                dialog._picker.Detach();
            }
        }
        finally
        {
            DialogGate.Exit();
        }
    }

    /// <summary>An emoji from a session or workspace file as the field shows it: its last emoji, else nothing.</summary>
    private static string Shown(string emoji) =>
        TabEmoji.Normalized(emoji) is { Length: <= DisplayText.MaxElementLength } kept ? DisplayText.Sanitize(kept) : string.Empty;

    /// <summary>The image, else the emoji, else none.</summary>
    private TabIconChoice Saved() =>
        new(_picker.Selection ?? (_field.Text.Length == 0 ? null : _field.Text));

    /// <summary>Keeps only the last emoji typed or picked (plain text leaves the field empty); an emoji clears the
    /// image.</summary>
    private void OnFieldTextChanged(object sender, TextChangedEventArgs e)
    {
        string text = _field.Text;
        // An emoji typed as two key events may show its first UTF-16 half alone: wait for the pair.
        if (_settingText || HasLoneSurrogate(text))
            return;
        string kept = Shown(text);
        if (!string.Equals(kept, text, StringComparison.Ordinal))
            SetField(kept);
        if (kept.Length > 0)
            _picker.Selection = null;
    }

    private static bool HasLoneSurrogate(string text)
    {
        for (int index = 0; index < text.Length; index++)
        {
            if (char.IsHighSurrogate(text[index]) && index + 1 < text.Length && char.IsLowSurrogate(text[index + 1]))
                index++;
            else if (char.IsSurrogate(text[index]))
                return true;
        }

        return false;
    }

    /// <summary>Sets the field's text without normalizing it again, the caret at its end.</summary>
    private void SetField(string text)
    {
        if (string.Equals(_field.Text, text, StringComparison.Ordinal))
            return;
        _settingText = true;
        try
        {
            _field.Text = text;
            _field.SelectionStart = text.Length;
        }
        finally
        {
            _settingText = false;
        }
    }

    /// <summary>Enter in the field saves, as the Mac's Return does.</summary>
    private void OnFieldKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter)
            return;
        e.Handled = true;
        _choice = Saved();
        Hide();
    }
}
