using System.Text.RegularExpressions;

namespace OpenMusic.Sync.Convex;

/// <summary>
/// Error text that came from the sync server, made safe to keep in an exception, a log line or a message on screen.
/// Convex's argument validation errors echo the request below the error ("Object: {deviceToken: "…", …}",
/// "Value: …", "Validator: …"), so a refused call would otherwise carry its device token, key or sealed payload
/// wherever its message goes. Everything from the first echo line on is dropped, values of secret-looking fields are
/// replaced, and anything shaped like a JWT or a long opaque token is replaced too.
/// </summary>
public static partial class ServerText
{
    private const int MaxLength = 300;
    private const string Redacted = "<redacted>";

    public static string Clean(string? text)
    {
        if (string.IsNullOrEmpty(text)) return "";
        var lines = text.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n');
        var kept = new List<string>();
        foreach (var line in lines)
        {
            if (EchoLine().IsMatch(line)) break;
            kept.Add(line);
        }
        var cleaned = string.Join("\n", kept).Trim();
        cleaned = SecretField().Replace(cleaned, m => m.Groups["lead"].Value + Redacted);
        cleaned = Jwt().Replace(cleaned, Redacted);
        cleaned = Opaque().Replace(cleaned, Redacted);
        return cleaned.Length > MaxLength ? cleaned[..MaxLength] + "…" : cleaned;
    }

    /// <summary>The lines where Convex starts echoing the call: its arguments, the value checked, the validator.</summary>
    [GeneratedRegex(@"^\s*(Object|Value|Validator|Args|Arguments|Received|Path to value)\s*:", RegexOptions.IgnoreCase)]
    private static partial Regex EchoLine();

    [GeneratedRegex(@"(?<lead>""?\b(?:[A-Za-z]*(?:token|Token|key|Key|secret|Secret|jwt|Jwt|cookie|Cookie|password|Password|signature|Signature|sealed|Sealed))""?\s*[:=]\s*)(?:""[^""]*""|'[^']*'|[^\s,}\]]+)")]
    private static partial Regex SecretField();

    [GeneratedRegex(@"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)?")]
    private static partial Regex Jwt();

    /// <summary>A run of 32 or more base64 or hex characters: no word in an error message looks like that.</summary>
    [GeneratedRegex(@"[A-Za-z0-9+/_=-]{32,}")]
    private static partial Regex Opaque();
}
