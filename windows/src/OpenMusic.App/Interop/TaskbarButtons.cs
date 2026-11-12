using OpenMusic.Core;
using Microsoft.Win32;
using static OpenMusic.App.Interop.Native;

namespace OpenMusic.App.Interop;

/// <summary>
/// Previous, Play/Pause and Next under the app's taskbar thumbnail (ITaskbarList3 thumbnail toolbar). The buttons are
/// added once Explorer says the taskbar button exists, and the middle one follows play/pause. Icons are drawn here in
/// the taskbar's foreground color (dark glyphs when the system uses the light theme).
/// </summary>
internal sealed class TaskbarButtons
{
    private const int PreviousId = 1, PlayPauseId = 2, NextId = 3;

    private readonly IntPtr _hwnd;
    private readonly PlayerController _player;
    private ITaskbarList3? _taskbar;
    private IntPtr _prev, _play, _pause, _next;
    private bool? _showingPause;
    private bool? _shownHasTrack;

    public TaskbarButtons(IntPtr hwnd, WindowHook hook, PlayerController player)
    {
        _hwnd = hwnd;
        _player = player;
        hook.TaskbarButtonCreated += Create;
        hook.ThumbButtonClicked += Clicked;
        player.AddChangeHandler(change =>
        {
            if (change is PlayerChange.State or PlayerChange.Track) Refresh();
        });
    }

    private void Create()
    {
        try
        {
            _taskbar ??= (ITaskbarList3)new TaskbarList();
            _taskbar.HrInit();
            var size = GetSystemMetricsForDpi(SM_CXSMICON, Math.Max(96u, GetDpiForWindow(_hwnd)));
            var light = SystemUsesLightTheme();
            DestroyIcons();
            _prev = Glyph(size, light, DrawPrevious);
            _play = Glyph(size, light, DrawPlay);
            _pause = Glyph(size, light, DrawPause);
            _next = Glyph(size, light, DrawNext);
            _showingPause = _player.IsPlaying;
            _taskbar.ThumbBarAddButtons(_hwnd, 3, Buttons());
        }
        catch (Exception)
        {
            _taskbar = null; // No taskbar (Explorer restarting, Server Core): the app works without the buttons.
        }
    }

    private void Refresh()
    {
        var hasTrack = _player.Current is not null;
        if (_taskbar is null || (_showingPause == _player.IsPlaying && _shownHasTrack == hasTrack)) return;
        _showingPause = _player.IsPlaying;
        try
        {
            _taskbar.ThumbBarUpdateButtons(_hwnd, 3, Buttons());
        }
        catch (Exception)
        {
            // Explorer restarted; TaskbarButtonCreated comes again and recreates them.
        }
    }

    private THUMBBUTTON[] Buttons()
    {
        var hasTrack = _player.Current is not null;
        _shownHasTrack = hasTrack;
        var flags = hasTrack ? THUMBBUTTONFLAGS.THBF_ENABLED : THUMBBUTTONFLAGS.THBF_DISABLED;
        const THUMBBUTTONMASK mask = THUMBBUTTONMASK.THB_ICON | THUMBBUTTONMASK.THB_TOOLTIP | THUMBBUTTONMASK.THB_FLAGS;
        var playing = _showingPause == true;
        return
        [
            new THUMBBUTTON { dwMask = mask, iId = PreviousId, hIcon = _prev, szTip = "Previous", dwFlags = flags },
            new THUMBBUTTON { dwMask = mask, iId = PlayPauseId, hIcon = playing ? _pause : _play, szTip = playing ? "Pause" : "Play", dwFlags = flags },
            new THUMBBUTTON { dwMask = mask, iId = NextId, hIcon = _next, szTip = "Next", dwFlags = flags },
        ];
    }

    private void Clicked(int id)
    {
        switch (id)
        {
            case PreviousId: _player.Previous(); break;
            case PlayPauseId: _player.TogglePlayPause(); break;
            case NextId: _player.Next(); break;
        }
    }

    private static bool SystemUsesLightTheme()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        return key?.GetValue("SystemUsesLightTheme") is int v && v == 1;
    }

    private void DestroyIcons()
    {
        foreach (var icon in new[] { _prev, _play, _pause, _next })
            if (icon != IntPtr.Zero) DestroyIcon(icon);
    }

    // Glyphs in unit coordinates (0…1, y down), rasterized with 4×4 supersampling.

    private delegate bool Shape(double x, double y);

    private static IntPtr Glyph(int size, bool light, Shape shape)
    {
        var bgra = new byte[size * size * 4];
        byte c = light ? (byte)0x1A : (byte)0xFF;
        for (var py = 0; py < size; py++)
        {
            for (var px = 0; px < size; px++)
            {
                var hits = 0;
                for (var sy = 0; sy < 4; sy++)
                    for (var sx = 0; sx < 4; sx++)
                        if (shape((px + (sx + 0.5) / 4) / size, (py + (sy + 0.5) / 4) / size)) hits++;
                var a = hits * 255 / 16;
                var o = (py * size + px) * 4;
                bgra[o] = bgra[o + 1] = bgra[o + 2] = (byte)(c * a / 255);
                bgra[o + 3] = (byte)a;
            }
        }
        return IconFromBgra(bgra, size);
    }

    private static bool Triangle(double x, double y, (double X, double Y) a, (double X, double Y) b, (double X, double Y) c)
    {
        static double Side((double X, double Y) p, (double X, double Y) q, double x, double y) => (q.X - p.X) * (y - p.Y) - (q.Y - p.Y) * (x - p.X);
        var d1 = Side(a, b, x, y);
        var d2 = Side(b, c, x, y);
        var d3 = Side(c, a, x, y);
        return !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0));
    }

    private static bool Box(double x, double y, double x0, double y0, double x1, double y1) => x >= x0 && x <= x1 && y >= y0 && y <= y1;

    private static bool DrawPlay(double x, double y) => Triangle(x, y, (0.28, 0.18), (0.28, 0.82), (0.82, 0.5));

    private static bool DrawPause(double x, double y) => Box(x, y, 0.25, 0.2, 0.42, 0.8) || Box(x, y, 0.58, 0.2, 0.75, 0.8);

    private static bool DrawNext(double x, double y) => Triangle(x, y, (0.2, 0.2), (0.2, 0.8), (0.66, 0.5)) || Box(x, y, 0.68, 0.2, 0.8, 0.8);

    private static bool DrawPrevious(double x, double y) => DrawNext(1 - x, y);
}
