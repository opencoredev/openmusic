using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace Medley.App.Services;

/// <summary>
/// Every keyboard shortcut, in one list: the shell registers them as KeyboardAccelerators and Help › Keyboard Shortcuts
/// shows the same list, so the two can't disagree.
/// </summary>
public static class Shortcuts
{
    public sealed record Shortcut(string Group, string Action, VirtualKey Key, VirtualKeyModifiers Modifiers, string Keys, Action Run, bool WhileTyping = false);

    public static IReadOnlyList<Shortcut> All { get; } = Build();

    private static IReadOnlyList<Shortcut> Build()
    {
        static ShellPage Shell() => ShellPage.Current;
        static Medley.Core.PlayerController Player() => App.Services.Player;
        const VirtualKeyModifiers Ctrl = VirtualKeyModifiers.Control;
        const VirtualKeyModifiers None = VirtualKeyModifiers.None;
        return
        [
            new("Playback", "Play or pause", VirtualKey.Space, None, "Space", () => Player().TogglePlayPause()),
            new("Playback", "Play or pause", VirtualKey.P, Ctrl, "Ctrl+P", () => Player().TogglePlayPause()),
            new("Playback", "Next song", VirtualKey.Right, Ctrl, "Ctrl+Right", () => Player().Next()),
            new("Playback", "Previous song", VirtualKey.Left, Ctrl, "Ctrl+Left", () => Player().Previous()),
            new("Playback", "Volume up", VirtualKey.Up, Ctrl, "Ctrl+Up", () => Player().Volume = Math.Min(1, Player().Volume + 0.05f)),
            new("Playback", "Volume down", VirtualKey.Down, Ctrl, "Ctrl+Down", () => Player().Volume = Math.Max(0, Player().Volume - 0.05f)),
            new("Playback", "Shuffle on or off", VirtualKey.S, Ctrl, "Ctrl+S", () => Player().Shuffle = !Player().Shuffle),
            new("Playback", "Repeat: off, all, one", VirtualKey.R, Ctrl, "Ctrl+R", () => App.Services.PlayerViewModel.CycleRepeat()),
            new("View", "Search", VirtualKey.F, Ctrl, "Ctrl+F", () => Shell().FocusSearch(), WhileTyping: true),
            new("View", "Lyrics", VirtualKey.L, Ctrl, "Ctrl+L", () => Shell().TogglePane(Controls.SidePaneTab.Lyrics), WhileTyping: true),
            new("View", "Up Next", VirtualKey.U, Ctrl, "Ctrl+U", () => Shell().TogglePane(Controls.SidePaneTab.UpNext), WhileTyping: true),
            new("View", "Now Playing", VirtualKey.N, Ctrl, "Ctrl+N", () => Shell().ShowNowPlaying(!Shell().IsNowPlayingOpen), WhileTyping: true),
            new("View", "Mini player", VirtualKey.M, Ctrl, "Ctrl+M", () => App.MainWindow?.ShowMiniPlayer(), WhileTyping: true),
            new("View", "Devices", VirtualKey.D, Ctrl, "Ctrl+D", () => Shell().ShowDevices(), WhileTyping: true),
            new("Go", "Back", VirtualKey.Left, VirtualKeyModifiers.Menu, "Alt+Left", () => Shell().GoBack(), WhileTyping: true),
            new("Go", "Home", VirtualKey.Number1, Ctrl, "Ctrl+1", () => Shell().Navigate("home"), WhileTyping: true),
            new("Go", "New", VirtualKey.Number2, Ctrl, "Ctrl+2", () => Shell().Navigate("new"), WhileTyping: true),
            new("Go", "Radio", VirtualKey.Number3, Ctrl, "Ctrl+3", () => Shell().Navigate("radio"), WhileTyping: true),
            new("Go", "Settings", (VirtualKey)188, Ctrl, "Ctrl+,", () => Shell().Navigate("settings"), WhileTyping: true),
            new("Go", "Keyboard shortcuts", (VirtualKey)191, Ctrl, "Ctrl+/", () => _ = ShowDialogAsync(), WhileTyping: true),
            new("Go", "Keyboard shortcuts", VirtualKey.F1, None, "F1", () => _ = ShowDialogAsync(), WhileTyping: true),
            new("Go", "Close Now Playing", VirtualKey.Escape, None, "Esc", () => Shell().ShowNowPlaying(false)),
        ];
    }

    /// <summary>Adds the accelerators to <paramref name="element"/>. Space is handled by the shell's key preview (it must
    /// not press the focused button), so it isn't an accelerator.</summary>
    public static void Register(UIElement element, Func<bool> isTyping)
    {
        element.KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
        foreach (var s in All.Where(s => s.Key != VirtualKey.Space))
        {
            var accelerator = new KeyboardAccelerator { Key = s.Key, Modifiers = s.Modifiers };
            accelerator.Invoked += (_, e) =>
            {
                if (ShellPage.Current.IsOnboarding) return;
                if (!s.WhileTyping && isTyping()) return;
                if (s.Key == VirtualKey.Escape && !ShellPage.Current.IsNowPlayingOpen) return;
                s.Run();
                e.Handled = true;
            };
            element.KeyboardAccelerators.Add(accelerator);
        }
    }

    /// <summary>Help › Keyboard Shortcuts.</summary>
    public static async Task ShowDialogAsync()
    {
        var list = new StackPanel { Spacing = 4, MinWidth = 420 };
        foreach (var group in All.GroupBy(s => s.Group))
        {
            list.Children.Add(new TextBlock
            {
                Text = group.Key,
                Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"],
                Margin = new Thickness(0, list.Children.Count == 0 ? 0 : 14, 0, 4),
            });
            foreach (var byAction in group.GroupBy(s => s.Action))
            {
                var row = new Grid { ColumnSpacing = 24, Padding = new Thickness(0, 3, 0, 3) };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.Children.Add(new TextBlock { Text = byAction.Key, VerticalAlignment = VerticalAlignment.Center });
                var keys = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
                foreach (var s in byAction) keys.Children.Add(KeyCap(s.Keys));
                Grid.SetColumn(keys, 1);
                row.Children.Add(keys);
                list.Children.Add(row);
            }
        }
        var dialog = new ContentDialog
        {
            Title = "Keyboard shortcuts",
            Content = new ScrollViewer { Content = list, MaxHeight = 520, Padding = new Thickness(0, 0, 16, 0) },
            CloseButtonText = "Close",
            DefaultButton = ContentDialogButton.Close,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(dialog, "ShortcutsDialog");
        await Dialogs.ShowAsync(dialog);
    }

    private static Border KeyCap(string keys) => new()
    {
        Style = Ui.Style("MedleyKeyCapStyle"),
        Child = new TextBlock { Text = keys, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"], FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Segoe UI Variable Text Semibold") },
    };
}

/// <summary>ContentDialogs one at a time (WinUI throws when a second opens), themed like the window.</summary>
public static class Dialogs
{
    private static readonly SemaphoreSlim Gate = new(1, 1);

    public static ContentDialog? Current { get; private set; }

    public static async Task<ContentDialogResult> ShowAsync(ContentDialog dialog)
    {
        await Gate.WaitAsync();
        try
        {
            if (App.MainWindow?.Shell is not { } shell) return ContentDialogResult.None;
            dialog.XamlRoot = shell.XamlRoot;
            dialog.RequestedTheme = shell.ActualTheme;
            dialog.Style ??= (Style)Application.Current.Resources["DefaultContentDialogStyle"];
            Current = dialog;
            return await dialog.ShowAsync();
        }
        finally
        {
            Current = null;
            Gate.Release();
        }
    }
}
