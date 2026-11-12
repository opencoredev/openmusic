using static Medley.App.Interop.Native;

namespace Medley.App.Interop;

/// <summary>Subclasses a window's procedure once for the shell's needs: the taskbar thumbnail toolbar (its creation
/// message and button clicks) and, for snapshots, a maximum track size larger than the screen.</summary>
internal sealed class WindowHook
{
    private readonly IntPtr _hwnd;
    private readonly SubclassProc _proc;
    private readonly uint _taskbarCreated = RegisterWindowMessage("TaskbarButtonCreated");

    public event Action? TaskbarButtonCreated;
    public event Action<int>? ThumbButtonClicked;

    /// <summary>Allow the window to be sized past the screen (snapshots at 1440x900 on a smaller screen).</summary>
    public bool AllowOversize { get; set; }

    /// <summary>The smallest client size in effective pixels (scaled by the window's DPI).</summary>
    public (int Width, int Height)? MinimumSize { get; set; }

    public WindowHook(IntPtr hwnd)
    {
        _hwnd = hwnd;
        _proc = Proc; // keep the delegate alive as long as the hook
        SetWindowSubclass(hwnd, _proc, 1, 0);
    }

    private IntPtr Proc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam, UIntPtr id, UIntPtr refData)
    {
        if (msg == _taskbarCreated)
        {
            TaskbarButtonCreated?.Invoke();
        }
        else if (msg == WM_COMMAND && ((long)wParam >> 16 & 0xFFFF) == THBN_CLICKED)
        {
            ThumbButtonClicked?.Invoke((int)((long)wParam & 0xFFFF));
            return IntPtr.Zero;
        }
        else if (msg == WM_GETMINMAXINFO && (AllowOversize || MinimumSize is not null))
        {
            var result = DefSubclassProc(hWnd, msg, wParam, lParam);
            var info = System.Runtime.InteropServices.Marshal.PtrToStructure<MINMAXINFO>(lParam);
            if (AllowOversize) info.ptMaxTrackSize = new POINT { X = 8000, Y = 8000 };
            if (MinimumSize is { } min)
            {
                var scale = GetDpiForWindow(hWnd) / 96.0;
                info.ptMinTrackSize = new POINT { X = (int)(min.Width * scale), Y = (int)(min.Height * scale) };
            }
            System.Runtime.InteropServices.Marshal.StructureToPtr(info, lParam, false);
            return result;
        }
        return DefSubclassProc(hWnd, msg, wParam, lParam);
    }
}
