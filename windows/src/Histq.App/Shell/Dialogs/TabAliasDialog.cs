using Histq.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace Histq.App.Shell.Dialogs;

/// <summary>
/// A tab's menu › Set Alias… (TabAliasModal, App/Window/ModalHost.swift): the tab's name in one field, the folder's name
/// as its placeholder. Enter or Save keeps it; an empty field gives the tab its folder's name back (WindowTabs.SetAlias
/// trims and caps it).
/// </summary>
internal sealed partial class TabAliasDialog : ContentDialog
{
    private readonly TextBox _field;
    private bool _saved;

    private TabAliasDialog(XamlRoot root, string folder, string? alias)
    {
        string name = DisplayText.Sanitize(folder);
        XamlRoot = root;
        if (Application.Current.Resources.TryGetValue("DefaultContentDialogStyle", out object? style) && style is Style dialogStyle)
            Style = dialogStyle;
        Title = $"Set an alias for {(name.Length == 0 ? "this tab" : name)}";
        PrimaryButtonText = "Save";
        CloseButtonText = "Cancel";
        DefaultButton = ContentDialogButton.Primary;

        _field = new TextBox
        {
            PlaceholderText = name.Length == 0 ? "Alias" : name,
            Text = DisplayText.Sanitize(alias),
            IsSpellCheckEnabled = false,
            IsTextPredictionEnabled = false,
        };
        AutomationProperties.SetName(_field, "Alias");
        _field.KeyDown += OnFieldKeyDown;

        var panel = new StackPanel { Spacing = 12, MinWidth = 360 };
        panel.Children.Add(new TextBlock
        {
            Text = "The tab shows this name instead of the folder's. Leave it empty to show the folder's name.",
            TextWrapping = TextWrapping.Wrap,
        });
        panel.Children.Add(_field);
        Content = panel;

        PrimaryButtonClick += (_, _) => _saved = true;
        Opened += (_, _) =>
        {
            _field.Focus(FocusState.Programmatic);
            _field.SelectAll();
        };
    }

    /// <summary>Asks for the alias of the tab whose folder is <paramref name="folder"/> (its current
    /// <paramref name="alias"/> filled in): the text to set when saved, null when cancelled or while one is up.</summary>
    public static async Task<string?> AskAsync(XamlRoot root, string folder, string? alias)
    {
        // A window shows one ContentDialog at a time.
        if (!DialogGate.TryEnter())
            return null;
        try
        {
            var dialog = new TabAliasDialog(root, folder, alias);
            await dialog.ShowAsync();
            return dialog._saved ? dialog._field.Text : null;
        }
        finally
        {
            DialogGate.Exit();
        }
    }

    /// <summary>Enter in the field saves, as the Mac's Return does.</summary>
    private void OnFieldKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter)
            return;
        e.Handled = true;
        _saved = true;
        Hide();
    }
}
