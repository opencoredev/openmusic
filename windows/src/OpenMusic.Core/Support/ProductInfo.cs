namespace OpenMusic.Core;

/// <summary>
/// The product's name and identifiers as listeners and Windows see them. Use these instead of spelling the name out.
/// </summary>
public static class ProductInfo
{
    /// <summary>The name shown in the UI, in messages, the title bar, the Start menu, the taskbar and the media flyout.</summary>
    public const string Name = "OpenMusic";

    /// <summary>The URL scheme registered per user (HKCU): the Clerk social sign-in callback and links handed to the app.</summary>
    public const string UrlScheme = "openmusic";

    /// <summary>The explicit AppUserModelID of the process and its Start menu shortcut.</summary>
    public const string AppUserModelId = "OpenMusic";

    /// <summary>Folder name under %LOCALAPPDATA% (settings, secrets, logs, caches).</summary>
    public const string FolderName = "OpenMusic";
}
