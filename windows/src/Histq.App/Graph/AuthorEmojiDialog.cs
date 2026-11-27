using Histq.App.Shell.Dialogs;
using Histq.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace Histq.App.Graph;

/// <summary>What Set Author Emoji… decided: the author's emoji, or null to remove it.</summary>
internal sealed record AuthorEmojiChoice(string? Emoji);

/// <summary>
/// The commit menu's Set Author Emoji… (AuthorEmojiModal, App/Window/ModalHost.swift at 6fa6d40): the author's emoji
/// avatar, kept on this machine for every repository (the authorEmojis preference), in one field that keeps only the last
/// emoji typed or picked (<see cref="TabEmoji.Normalized"/>), with a hint for the Win+. emoji panel (the Mac's Choose
/// opens the Character Viewer). Enter or Save keeps it (an empty field removes it); Remove, shown when one is set,
/// removes it. No icon library, no git write.
/// </summary>
internal sealed partial class AuthorEmojiDialog : ContentDialog
{
    private readonly TextBox _field;
    private AuthorEmojiChoice? _choice;

    /// <summary>The field's text is being set from code: its TextChanged does not normalize it again.</summary>
    private bool _settingText;

    private AuthorEmojiDialog(XamlRoot root, string email, string name, string? current)
    {
        string shownName = DisplayText.Sanitize(name);
        string shownEmail = DisplayText.Sanitize(email);
        XamlRoot = root;
        if (Application.Current.Resources.TryGetValue("DefaultContentDialogStyle", out object? style) && style is Style dialogStyle)
            Style = dialogStyle;
        Title = $"Set an emoji for {(shownName.Length == 0 ? shownEmail : shownName)}";
        PrimaryButtonText = "Save";
        CloseButtonText = "Cancel";
        DefaultButton = ContentDialogButton.Primary;
        if (current is not null)
            SecondaryButtonText = "Remove";

        _field = new TextBox
        {
            PlaceholderText = "Emoji",
            Text = current is null ? string.Empty : Shown(current),
            IsSpellCheckEnabled = false,
            IsTextPredictionEnabled = false,
        };
        AutomationProperties.SetName(_field, "Emoji");
        _field.TextChanged += OnFieldTextChanged;
        _field.KeyDown += OnFieldKeyDown;

        var panel = new StackPanel { Spacing = 12, MinWidth = 360 };
        panel.Children.Add(new TextBlock
        {
            Text = $"Shown as {shownEmail}'s avatar in every repository on this computer. Leave it empty for none.",
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
        Content = panel;

        PrimaryButtonClick += (_, _) => _choice = Saved();
        SecondaryButtonClick += (_, _) => _choice = new AuthorEmojiChoice(null);
        Opened += (_, _) =>
        {
            _field.Focus(FocusState.Programmatic);
            _field.SelectAll();
        };
    }

    /// <summary>Asks for the emoji of the author (<paramref name="email"/>, <paramref name="name"/>, raw), its
    /// <paramref name="current"/> one filled in: the choice when saved or removed, null when cancelled or while another
    /// dialog is up.</summary>
    public static async Task<AuthorEmojiChoice?> AskAsync(XamlRoot root, string email, string name, string? current)
    {
        if (!DialogGate.TryEnter())
            return null;
        try
        {
            var dialog = new AuthorEmojiDialog(root, email, name, current);
            await dialog.ShowAsync();
            return dialog._choice;
        }
        finally
        {
            DialogGate.Exit();
        }
    }

    /// <summary>The field's emoji as shown: its last emoji, else nothing.</summary>
    private static string Shown(string emoji) =>
        TabEmoji.Normalized(emoji) is { Length: <= DisplayText.MaxElementLength } kept ? DisplayText.Sanitize(kept) : string.Empty;

    /// <summary>The field's emoji normalized again (its TextChanged may not have run: a lone surrogate, Enter at
    /// once); none removes it.</summary>
    private AuthorEmojiChoice Saved() => new(Shown(_field.Text) is { Length: > 0 } emoji ? emoji : null);

    /// <summary>Keeps only the last emoji typed or picked (plain text leaves the field empty).</summary>
    private void OnFieldTextChanged(object sender, TextChangedEventArgs e)
    {
        string text = _field.Text;
        // An emoji typed as two key events may show its first UTF-16 half alone: wait for the pair.
        if (_settingText || HasLoneSurrogate(text))
            return;
        string kept = Shown(text);
        if (string.Equals(kept, text, StringComparison.Ordinal))
            return;
        _settingText = true;
        try
        {
            _field.Text = kept;
            _field.SelectionStart = kept.Length;
        }
        finally
        {
            _settingText = false;
        }
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
