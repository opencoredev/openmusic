#if DEBUG
using Medley.App.Controls;
using Medley.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;

namespace Medley.App.Services;

/// <summary>
/// Debug builds only: <c>--self-test &lt;file&gt;</c> reads commands appended to a file (one per line) and runs them in
/// the real window, logging "selftest: done N &lt;command&gt;" after each. It lets a script in the VM put the app in a
/// state (a screen, a pane, an open menu or flyout) for a screen capture, where QEMU has no mouse. It reads the file
/// twice a second only while the self-test runs; normal launches never start it.
/// </summary>
public static class SelfTest
{
    public static async Task RunAsync(string file)
    {
        Log.Info($"selftest: watching {file}");
        var done = 0;
        while (true)
        {
            await Task.Delay(500);
            string[] lines;
            try { lines = File.Exists(file) ? await File.ReadAllLinesAsync(file) : []; }
            catch (IOException) { continue; }
            for (; done < lines.Length; done++)
            {
                var line = lines[done].Trim();
                if (line.Length == 0 || line.StartsWith('#')) continue;
                try
                {
                    if (!await Run(line)) return;
                    Log.Info($"selftest: done {done + 1} {line}");
                }
                catch (Exception e)
                {
                    Log.Error($"selftest: failed {done + 1} {line}: {e.GetType().Name}: {e.Message}");
                }
            }
        }
    }

    private static async Task<bool> Run(string line)
    {
        var shell = ShellPage.Current;
        var window = App.MainWindow!;
        var services = App.Services;
        var parts = line.Split(' ', 2, StringSplitOptions.TrimEntries);
        var arg = parts.Length > 1 ? parts[1] : "";
        switch (parts[0])
        {
            case "screen": await shell.OpenScreenAsync(arg); break;
            case "theme": window.SetTheme(arg switch { "dark" => ElementTheme.Dark, "light" => ElementTheme.Light, _ => ElementTheme.Default }); break;
            case "size":
                var wh = arg.Split('x');
                window.ResizeClient(int.Parse(wh[0], System.Globalization.CultureInfo.InvariantCulture), int.Parse(wh[1], System.Globalization.CultureInfo.InvariantCulture));
                break;
            case "pane": shell.ShowPane(arg switch { "lyrics" => SidePaneTab.Lyrics, "queue" => SidePaneTab.UpNext, _ => null }); break;
            case "nowplaying": shell.ShowNowPlaying(arg != "off"); break;
            case "mini":
                if (arg == "off") window.MiniPlayer?.Close();
                else window.ShowMiniPlayer();
                break;
            case "devices": shell.ShowDevices(); break;
            case "close-devices": shell.CloseDevices(); break;
            case "onboarding":
                // "onboarding [welcome|music|sync]": the first run at that step.
                shell.ShowOnboarding(arg switch { "music" => OnboardingView.Step.Music, "sync" => OnboardingView.Step.Sync, _ => OnboardingView.Step.Welcome });
                break;
            case "fake-youtube":
                // "fake-youtube <name>": a test YouTube Music sign-in (needs --test-sign-ins); YouTube itself rejects it.
                if (services.Sync?.YouTubeTransfer is not { } transfer) throw new InvalidOperationException("no YouTube sign-in transfer");
                await transfer.ImportSignInAsync(Medley.Providers.YouTube.Sync.YouTubeMusicSignInTransfer.TestPayload(arg.Length > 0 ? arg : "Riley Chen"));
                break;
            case "sync-signout":
                // Signs this PC out of the account (it leaves the device list), so a later run registers it fresh.
                if (services.Sync is { } s2) await s2.SignOutAsync();
                break;
            case "front": window.BringToFront(); break;
            case "youtube-signout":
                if (services.YouTube is { } yt) await yt.TrySignOutAsync();
                break;
            case "focus":
                // "focus <AutomationId>": keyboard focus on a control (as Tab would leave it), for focus-state captures.
                if (Find(arg) is Control focusable) focusable.Focus(FocusState.Keyboard);
                else throw new InvalidOperationException($"{arg} can't take focus");
                break;
            case "medley-signin": _ = shell.SignInToMedleyAsync(); break;
            case "server": if (services.Sync is { } s1) _ = MedleySignInDialog.ShowServerAsync(s1); break;
            case "youtube-signin": shell.SignInToYouTube(); break;
            case "shortcuts": _ = Shortcuts.ShowDialogAsync(); break;
            case "close-dialog": Dialogs.Current?.Hide(); break;
            case "account-menu": shell.OpenAccountMenu(); break;
            case "menu": OpenMenu(arg); break;
            case "click": Click(arg); break;
            case "type":
                // "type SignInEmail someone@example.com": sets a text box's text, as typing would.
                var (id, text) = arg.Split(' ', 2) is { Length: 2 } it ? (it[0], it[1]) : (arg, "");
                if (Find(id) is TextBox box) box.Text = text;
                else throw new InvalidOperationException($"{id} isn't a text box");
                break;
            case "play-first": PlayFirst(); break;
            case "play-search":
                // "play-search daft punk | one more time": search, then play the first song whose title matches.
                var (query, title) = arg.Split('|', 2, StringSplitOptions.TrimEntries) is { Length: 2 } qt ? (qt[0], qt[1]) : (arg, "");
                var results = await services.Provider.SearchAsync(query, SearchScope.Songs);
                var track = results.Tracks.FirstOrDefault(t => title.Length == 0 || t.Title.Contains(title, StringComparison.OrdinalIgnoreCase)) ?? results.Tracks.First();
                services.Player.Play(results.Tracks.ToList(), startAt: results.Tracks.ToList().IndexOf(track), context: new PlaybackContext(PlaybackContextKind.Search, query));
                Log.Info($"selftest: playing {track.Title} by {track.ArtistLine}");
                break;
            case "radio": await services.Player.PlayRadioAsync(services.Player.Current!); break;
            case "next": services.Player.Next(); break;
            case "jump-last": services.Player.Jump(services.Player.Queue[^1].Uid); break;
            case "seek-end": services.Player.Seek(Math.Max(0, (services.Player.Duration ?? 0) - double.Parse(arg, System.Globalization.CultureInfo.InvariantCulture))); break;
            case "pause": services.Player.Pause(); break;
            case "resume": services.Player.Resume(); break;
            case "seek": services.Player.Seek(double.Parse(arg, System.Globalization.CultureInfo.InvariantCulture)); break;
            case "state":
                var sync = services.Sync;
                Log.Info($"selftest: state {services.Player.State} \"{services.Player.Current?.Title}\" at {services.Player.CurrentTime:F1}s, queue {services.Player.Queue.Count} (up next {services.Player.UpNext.Count}), " +
                         $"youtube {services.Provider.AuthStatus.State} {services.Provider.AuthStatus.Account?.Name}, medley {(sync?.Account.IsSignedIn == true ? "signed in" : "signed out")}, " +
                         $"registered {sync?.Service.IsRegistered}, key {(sync is null ? "-" : SyncHub.Describe(sync.Service.KeyStatus))}, devices {sync?.Service.Devices.Count}, " +
                         $"continue {sync?.ContinueSuggestion?.Device.Name ?? "-"}, playback rows {(sync is null ? "-" : string.Join("; ", sync.Service.Playback.Values.Select(r => $"{sync.DeviceName(r.DeviceId)}: {r.Track?.Title ?? "(sealed)"} playing={r.Anchor.IsPlaying}")))}, lyrics {services.PlayerViewModel.LyricLines.Count} line(s) at {services.PlayerViewModel.CurrentLyricIndex}");
                break;
            case "bounds": LogBounds(arg); break;
            case "close-suggestions": shell.CloseSuggestions(); break;
            case "close-menu":
                foreach (var popup in Microsoft.UI.Xaml.Media.VisualTreeHelper.GetOpenPopupsForXamlRoot(shell.XamlRoot)) popup.IsOpen = false;
                break;
            case "close-youtube-signin": YouTubeSignInWindow.CloseOpen(); break;
            case "continue": shell.SetContinueBarOpen(arg != "off"); break;
            case "place":
                var xy = arg.Split(' ', StringSplitOptions.RemoveEmptyEntries).Select(v => int.Parse(v, System.Globalization.CultureInfo.InvariantCulture)).ToArray();
                window.AppWindow.Move(new Windows.Graphics.PointInt32(xy[0], xy[1]));
                break;
            case "scroll": await ScrollAsync(arg); break;
            case "suggest": await shell.ShowSuggestionsAsync(arg); break;
            case "preview": Preview(arg); break;
            case "onboarding-state":
                Log.Info($"selftest: onboarding {(shell.IsOnboarding ? "showing" : "hidden")}, welcomeDone {services.Settings.Values.WelcomeDone}, resume {services.Settings.Values.OnboardingResume ?? "-"}");
                break;
            case "memory":
                GC.Collect();
                var p = System.Diagnostics.Process.GetCurrentProcess();
                Log.Info($"selftest: memory working set {p.WorkingSet64 / 1048576.0:F1} MB, private {p.PrivateMemorySize64 / 1048576.0:F1} MB, managed {GC.GetTotalMemory(false) / 1048576.0:F1} MB, cpu {p.TotalProcessorTime.TotalMilliseconds:F0} ms, " +
                         $"art cache {ArtworkLoader.Shared.Usage.Bytes / 1048576.0:F1} MB in {ArtworkLoader.Shared.Usage.Count} images, files {ArtworkLoader.Shared.Usage.FileBytes / 1048576.0:F1} MB");
                break;
            case "quit":
                Application.Current.Exit();
                return false;
            default:
                Log.Error($"selftest: unknown command {line}");
                break;
        }
        return true;
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [System.Runtime.InteropServices.DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out NativeRect value, int size);

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct NativeRect { public int Left, Top, Right, Bottom; }

    /// <summary>"selftest: bounds x y w h": the foreground window's visible frame (no shadow) in screen pixels, so a
    /// script can crop a screenshot of the VM's screen to it.</summary>
    private static void LogBounds(string which)
    {
        var hwnd = which switch
        {
            "main" => App.MainWindow!.Hwnd,
            "mini" when App.MainWindow!.MiniPlayer is { } mini => WinRT.Interop.WindowNative.GetWindowHandle(mini),
            "youtube" when YouTubeSignInWindow.OpenHandle is { } h => h,
            _ => GetForegroundWindow(),
        };
        if (hwnd == IntPtr.Zero) hwnd = App.MainWindow!.Hwnd;
        const int ExtendedFrameBounds = 9;
        DwmGetWindowAttribute(hwnd, ExtendedFrameBounds, out var r, System.Runtime.InteropServices.Marshal.SizeOf<NativeRect>());
        Log.Info($"selftest: bounds {r.Left} {r.Top} {r.Right - r.Left} {r.Bottom - r.Top}");
    }

    /// <summary>Scrolls the page's main scroller: <c>end</c>, <c>top</c>, a number of pixels, or <c>step</c> (one
    /// screen down). <c>scroll all</c> walks to the end a screen at a time so every shelf is realized.</summary>
    private static async Task ScrollAsync(string how)
    {
        var scroller = FindAll<ScrollViewer>(ShellPage.Current.ContentFrameElement).OrderByDescending(s => s.ScrollableHeight).FirstOrDefault()
            ?? throw new InvalidOperationException("no scroller");
        switch (how)
        {
            case "end": scroller.ChangeView(null, scroller.ScrollableHeight, null, true); break;
            case "top": scroller.ChangeView(null, 0, null, true); break;
            case "step": scroller.ChangeView(null, scroller.VerticalOffset + scroller.ViewportHeight * 0.9, null, true); break;
            case "all":
                for (var i = 0; i < 60 && scroller.VerticalOffset < scroller.ScrollableHeight - 1; i++)
                {
                    scroller.ChangeView(null, scroller.VerticalOffset + scroller.ViewportHeight * 0.8, null, true);
                    await Task.Delay(600);
                }
                break;
            default: scroller.ChangeView(null, double.Parse(how, System.Globalization.CultureInfo.InvariantCulture), null, true); break;
        }
        await Task.Delay(100);
        Log.Info($"selftest: scrolled to {scroller.VerticalOffset:F0} of {scroller.ScrollableHeight:F0}");
    }

    /// <summary>The account dialogs with sample data (no account or second device needed), for screenshots.</summary>
    private static void Preview(string line)
    {
        var holder = new Medley.Sync.DeviceId("PREVIEW-HOLDER");
        // "preview allow Riley's PC|033968": the holder's prompt for that device and code.
        var (what, extra) = line.Split(' ', 2) is { Length: 2 } wl ? (wl[0], wl[1].Split('|')) : (line, Array.Empty<string>());
        switch (what)
        {
            case "signin": _ = MedleySignInDialog.ShowPreviewAsync("email"); break;
            case "signin-code": _ = MedleySignInDialog.ShowPreviewAsync("code"); break;
            case "compare": _ = KeyDialogs.CompareAsync(null, new Medley.Sync.KeyComparison("588783", holder, "Riley's iPhone", Allowed: false, Confirmed: false)); break;
            case "approve":
                ShellPage.Current.ShowOnboarding(OnboardingView.Step.Sync);
                ShellPage.Current.OnboardingPreviewApprove("Riley's iPhone", "588783");
                break;
            case "allow":
                var device = new Medley.Sync.SyncDevice { Id = holder, Name = extra.ElementAtOrDefault(0) ?? "Riley's MacBook Pro", Platform = Medley.Core.Sync.DevicePlatform.Mac, Model = "MacBookPro18,3", AppVersion = "1.0" };
                _ = KeyDialogs.AllowAsync(null, new Medley.Sync.KeyRequest(device, extra.ElementAtOrDefault(1) ?? "204617", "preview"));
                break;
            default: throw new InvalidOperationException($"no preview {what}");
        }
    }

    /// <summary>Opens the right-click menu of the first song row (or card) on the page.</summary>
    private static void OpenMenu(string what)
    {
        var root = ShellPage.Current.ContentFrameElement;
        ListViewBase? list = what == "card"
            ? FindAll<ListViewBase>(root).FirstOrDefault(l => l.Items.Count > 0 && l.Items[0] is ViewModels.CardItem)
            : FindAll<ListViewBase>(root).FirstOrDefault(l => l.Items.Count > 0 && l.Items[0] is ViewModels.TrackRow);
        if (list?.ContainerFromIndex(0) is not FrameworkElement container) throw new InvalidOperationException("no row to open a menu on");
        var flyout = list.Items[0] switch
        {
            ViewModels.TrackRow row => MediaMenus.ForTrack(row.Track),
            ViewModels.CardItem card => MediaMenus.For(card.Item),
            _ => null,
        };
        if (flyout is not null) ListHelpers.ShowMenu(flyout, container, new Windows.Foundation.Point(container.ActualWidth / 3, container.ActualHeight / 2));
    }

    /// <summary>Presses the control with this AutomationId, in the window or an open popup (flyouts and menus, which
    /// the VM's UI Automation script can't reach), through its automation peer as a click would.</summary>
    private static FrameworkElement Find(string id)
    {
        var shell = ShellPage.Current;
        var roots = new List<DependencyObject>();
        // Popups first (an open dialog's buttons over the page's).
        roots.AddRange(Microsoft.UI.Xaml.Media.VisualTreeHelper.GetOpenPopupsForXamlRoot(shell.XamlRoot).Select(p => (DependencyObject)p.Child).Where(c => c is not null));
        roots.Add(shell);
        return roots.SelectMany(r => FindAll<FrameworkElement>(r).Prepend(r as FrameworkElement).OfType<FrameworkElement>())
            .FirstOrDefault(e => Microsoft.UI.Xaml.Automation.AutomationProperties.GetAutomationId(e) == id || (e.Name == id && e is Button))
            ?? throw new InvalidOperationException($"no element {id}");
    }

    private static void Click(string id)
    {
        var target = Find(id);
        var peer = Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer.CreatePeerForElement(target);
        if (peer?.GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke) is Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider invoke) invoke.Invoke();
        else throw new InvalidOperationException($"{id} can't be invoked");
    }

    private static void PlayFirst()
    {
        var list = FindAll<ListViewBase>(ShellPage.Current.ContentFrameElement).FirstOrDefault(l => l.Items.Count > 0 && l.Items[0] is ViewModels.TrackRow);
        if (list?.Items.OfType<ViewModels.TrackRow>().ToList() is { Count: > 0 } rows) App.Services.Player.Play(rows.Select(r => r.Track).ToList(), startAt: 0);
    }

    private static IEnumerable<T> FindAll<T>(DependencyObject root) where T : DependencyObject
    {
        var count = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(root);
        for (var i = 0; i < count; i++)
        {
            var child = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(root, i);
            if (child is T match) yield return match;
            foreach (var deeper in FindAll<T>(child)) yield return deeper;
        }
    }
}
#endif
