using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace OpenMusic.App.Interop;

/// <summary>
/// Gives the unpackaged process an explicit AppUserModelID and a Start menu shortcut carrying it, as an installer
/// would, so the Windows media flyout, the taskbar and notifications say "OpenMusic" instead of "Unknown app". Per user,
/// no admin rights; the shortcut is rewritten only when it points at another exe.
/// </summary>
internal static partial class AppIdentity
{
    public const string AppUserModelId = OpenMusic.Core.ProductInfo.AppUserModelId;

    [LibraryImport("shell32.dll", StringMarshalling = StringMarshalling.Utf16)]
    private static partial int SetCurrentProcessExplicitAppUserModelID(string appId);

    public static void Apply()
    {
        try
        {
            SetCurrentProcessExplicitAppUserModelID(AppUserModelId);
            using (var key = Registry.CurrentUser.CreateSubKey($@"Software\Classes\AppUserModelId\{AppUserModelId}"))
            {
                key.SetValue("DisplayName", OpenMusic.Core.ProductInfo.Name);
                var icon = Path.Combine(AppContext.BaseDirectory, "Assets", "OpenMusic.png");
                if (File.Exists(icon)) key.SetValue("IconUri", icon);
            }
            EnsureShortcut();
        }
        catch (Exception e)
        {
            Services.Log.Error("app identity", e);
        }
    }

    private static void EnsureShortcut()
    {
        var exe = Environment.ProcessPath;
        if (exe is null) return;
        var programs = Environment.GetFolderPath(Environment.SpecialFolder.Programs);
        var path = Path.Combine(programs, OpenMusic.Core.ProductInfo.Name + ".lnk");
        var ico = Path.Combine(AppContext.BaseDirectory, "Assets", "OpenMusic.ico");
        if (File.Exists(path))
        {
            var existing = (IShellLinkW)new CShellLink();
            ((IPersistFile)existing).Load(path, 0);
            var target = new char[1024];
            existing.GetPath(target, target.Length, IntPtr.Zero, 0);
            // A shortcut written before the rename names Assets\Medley.ico, which builds since don't ship: rewrite it.
            var icon = new char[1024];
            existing.GetIconLocation(icon, icon.Length, out _);
            if (string.Equals(Text(target), exe, StringComparison.OrdinalIgnoreCase)
                && (!File.Exists(ico) || string.Equals(Text(icon), ico, StringComparison.OrdinalIgnoreCase))) return;
        }
        // A fresh link to write: one loaded read-only refuses property changes (STG_E_ACCESSDENIED).
        var link = (IShellLinkW)new CShellLink();
        link.SetPath(exe);
        link.SetWorkingDirectory(Path.GetDirectoryName(exe)!);
        link.SetDescription(OpenMusic.Core.ProductInfo.Name);
        if (File.Exists(ico)) link.SetIconLocation(ico, 0);
        var store = (IPropertyStore)link;
        var key = new PropertyKey { FormatId = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), PropertyId = 5 };
        var value = new PropVariant { VarType = 31 /* VT_LPWSTR */, Pointer = Marshal.StringToCoTaskMemUni(AppUserModelId) };
        try
        {
            store.SetValue(ref key, ref value);
            store.Commit();
        }
        finally
        {
            Marshal.FreeCoTaskMem(value.Pointer);
        }
        Directory.CreateDirectory(programs);
        ((IPersistFile)link).Save(path, true);
    }

    /// <summary>The text of a NUL-terminated buffer filled by the shell.</summary>
    private static string Text(char[] buffer) => new(buffer, 0, Array.IndexOf(buffer, '\0') is var end and >= 0 ? end : buffer.Length);

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct PropertyKey
    {
        public Guid FormatId;
        public uint PropertyId;
    }

    [StructLayout(LayoutKind.Explicit, Size = 24)]
    private struct PropVariant
    {
        [FieldOffset(0)] public ushort VarType;
        [FieldOffset(8)] public IntPtr Pointer;
    }

    [ComImport, Guid("00021401-0000-0000-C000-000000000046"), ClassInterface(ClassInterfaceType.None)]
    private class CShellLink;

    [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellLinkW
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] char[] file, int cch, IntPtr findData, uint flags);
        void GetIDList(out IntPtr idl);
        void SetIDList(IntPtr idl);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] char[] name, int cch);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] char[] dir, int cch);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string dir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] char[] args, int cch);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string args);
        void GetHotkey(out short hotkey);
        void SetHotkey(short hotkey);
        void GetShowCmd(out int showCmd);
        void SetShowCmd(int showCmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] char[] iconPath, int cch, out int icon);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string iconPath, int icon);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, uint reserved);
        void Resolve(IntPtr hwnd, uint flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string file);
    }

    [ComImport, Guid("0000010b-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPersistFile
    {
        void GetClassID(out Guid clsid);
        [PreserveSig] int IsDirty();
        void Load([MarshalAs(UnmanagedType.LPWStr)] string file, uint mode);
        void Save([MarshalAs(UnmanagedType.LPWStr)] string file, [MarshalAs(UnmanagedType.Bool)] bool remember);
        void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string file);
        void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string file);
    }

    [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPropertyStore
    {
        void GetCount(out uint count);
        void GetAt(uint index, out PropertyKey key);
        void GetValue(ref PropertyKey key, out PropVariant value);
        void SetValue(ref PropertyKey key, ref PropVariant value);
        void Commit();
    }
}
