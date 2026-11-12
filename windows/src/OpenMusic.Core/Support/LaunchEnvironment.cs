namespace OpenMusic.Core;

/// <summary>
/// Environment variables by their OpenMusic names, which still answer to the names from before the rename:
/// <c>MEDLEY_&lt;name&gt;</c> for <c>OPENMUSIC_&lt;name&gt;</c>, so older scripts keep working. Read every
/// <c>OPENMUSIC_*</c> variable through here.
/// </summary>
public static class LaunchEnvironment
{
    private const string Prefix = "OPENMUSIC_";
    private const string LegacyPrefix = "MEDLEY_";

    /// <summary>The value of <paramref name="name"/> (an <c>OPENMUSIC_*</c> name), or of its <c>MEDLEY_*</c> spelling when
    /// that one is unset.</summary>
    public static string? Get(string name) => Get(name, Environment.GetEnvironmentVariable);

    /// <summary><see cref="Get(string)"/> over another environment, for tests.</summary>
    public static string? Get(string name, Func<string, string?> lookup)
    {
        ArgumentNullException.ThrowIfNull(name);
        ArgumentNullException.ThrowIfNull(lookup);
        if (lookup(name) is { } value) return value;
        return name.StartsWith(Prefix, StringComparison.Ordinal) ? lookup(LegacyPrefix + name[Prefix.Length..]) : null;
    }
}
