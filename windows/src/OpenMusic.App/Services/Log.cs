namespace OpenMusic.App.Services;

/// <summary>A plain text log at %LOCALAPPDATA%\OpenMusic\logs\openmusic.log (rotated at 1 MB), for debugging over SSH.
/// Never log tokens, cookies or account data.</summary>
public static partial class Log
{
    private static readonly Lock Gate = new();
    public static string Path { get; } = System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), OpenMusic.Core.ProductInfo.FolderName, "logs", "openmusic.log");

    public static void Info(string message) => Write("INFO", message);

    public static void Error(string message, Exception? e = null) => Write("ERROR", e is null ? message : $"{message}: {e}");

    /// <summary>
    /// Server errors can carry the request back in their text (Convex's validation errors echo every argument, the
    /// device token included), and exception text reaches the log and InfoBars: strip anything shaped like a secret.
    /// </summary>
    public static string Redact(string text)
    {
        if (text.Length == 0) return text;
        text = SecretArg().Replace(text, m => $"{m.Groups[1].Value}<redacted>{m.Groups[3].Value}");
        text = Bearer().Replace(text, "Bearer <redacted>");
        text = Cookie().Replace(text, m => $"{m.Groups[1].Value}=<redacted>");
        // Convex's "Object: {…}" echo of the arguments: nothing in it is needed to understand the error.
        return ObjectEcho().Replace(text, "Object: <arguments left out>");
    }

    [System.Text.RegularExpressions.GeneratedRegex(@"(""?(?:token|jwt|sealed|secret|key|cookie|refreshToken|accessToken|clientToken|deviceKey|proposedKey)""?\s*[:=]\s*"")([^""]*)("")", System.Text.RegularExpressions.RegexOptions.IgnoreCase)]
    private static partial System.Text.RegularExpressions.Regex SecretArg();

    [System.Text.RegularExpressions.GeneratedRegex(@"Bearer\s+[A-Za-z0-9\-._~+/=]+")]
    private static partial System.Text.RegularExpressions.Regex Bearer();

    [System.Text.RegularExpressions.GeneratedRegex(@"\b(SAPISID|APISID|SID|HSID|SSID|LOGIN_INFO|__Secure-[0-9A-Za-z-]+)=[^;\s""]+")]
    private static partial System.Text.RegularExpressions.Regex Cookie();

    [System.Text.RegularExpressions.GeneratedRegex(@"Object: \{.*?\}\s*(?=\r?\nValidator:|$)", System.Text.RegularExpressions.RegexOptions.Singleline)]
    private static partial System.Text.RegularExpressions.Regex ObjectEcho();

    private static void Write(string level, string message)
    {
        message = Redact(message);
        try
        {
            lock (Gate)
            {
                Directory.CreateDirectory(System.IO.Path.GetDirectoryName(Path)!);
                var info = new FileInfo(Path);
                if (info.Exists && info.Length > 1_000_000) File.Move(Path, Path + ".1", overwrite: true);
                File.AppendAllText(Path, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {level} {message}{Environment.NewLine}");
            }
        }
        catch (IOException)
        {
        }
    }
}
