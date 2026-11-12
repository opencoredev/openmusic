import Foundation

/// Environment variables and launch arguments by their OpenMusic names, which still answer to the names from before
/// the rename: `MEDLEY_<name>` for `OPENMUSIC_<name>` and `-Medley<name>` for `-OpenMusic<name>`, so older scripts and
/// saved command lines keep working. Read every `OPENMUSIC_*` variable and `-OpenMusic*` argument through here.
public enum LaunchEnvironment {
    static let prefix = "OPENMUSIC_"
    static let legacyPrefix = "MEDLEY_"
    static let argumentPrefix = "-OpenMusic"
    static let legacyArgumentPrefix = "-Medley"

    /// This process's environment, each `MEDLEY_<name>` also visible as `OPENMUSIC_<name>` unless that is set.
    public static let current = withLegacyNames(ProcessInfo.processInfo.environment)

    /// `environment` with each `MEDLEY_<name>` copied to `OPENMUSIC_<name>` where that isn't set.
    public static func withLegacyNames(_ environment: [String: String]) -> [String: String] {
        var merged = environment
        for (key, value) in environment where key.hasPrefix(legacyPrefix) {
            let name = prefix + key.dropFirst(legacyPrefix.count)
            if merged[name] == nil { merged[name] = value }
        }
        return merged
    }

    /// The value after `-OpenMusic<name>` in `arguments`, or after the older `-Medley<name>` when that is absent.
    public static func argument(_ name: String, in arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
        for flag in [argumentPrefix + name, legacyArgumentPrefix + name] {
            if let i = arguments.firstIndex(of: flag), arguments.indices.contains(i + 1) { return arguments[i + 1] }
        }
        return nil
    }
}
