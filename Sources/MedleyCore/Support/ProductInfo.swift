import Foundation

/// The product's name and identifiers as listeners and the system see them. The product is OpenMusic; the code keeps
/// the Medley module, type and folder names internally (AGENTS.md). Use these instead of spelling the name out.
public enum ProductInfo {
    /// The name shown in the UI, in messages and to other apps.
    public static let name = "OpenMusic"
    /// The URL scheme the apps register: the Clerk social sign-in callback (`openmusic://oauth-callback`), the Spotify
    /// custom-scheme redirect and Debug self-test links.
    public static let urlScheme = "openmusic"
    /// The Mac app's bundle identifier (`Resources/Info.plist`).
    public static let macBundleIdentifier = "dev.openmusic.OpenMusic"
    /// Folder name under Application Support and Caches.
    public static let folderName = "OpenMusic"
    /// Prefix for log subsystems, queue labels and other reverse-DNS names.
    public static let identifierPrefix = "dev.openmusic"
}
