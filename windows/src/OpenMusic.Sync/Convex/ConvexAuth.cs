using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace OpenMusic.Sync.Convex;

/// <summary>
/// Supplies the JWT the Convex client authenticates with (a Clerk session token from the <c>convex</c> template).
/// <see cref="Account.ClerkClient"/> is the real one; tests use a fake.
/// </summary>
public interface IAuthTokenProvider
{
    /// <summary>
    /// The current token, or null when signed out. With <paramref name="forceRefresh"/>, skip any cached token. Throws
    /// when it can't be fetched right now (offline); the client retries.
    /// </summary>
    Task<string?> GetTokenAsync(bool forceRefresh, CancellationToken cancellationToken = default);
}

/// <summary>Where the client's identity stands.</summary>
public abstract record ConvexAuthState
{
    /// <summary>No token provider, or it says signed out.</summary>
    public sealed record None : ConvexAuthState;
    /// <summary>A token was sent; the server hasn't confirmed it yet.</summary>
    public sealed record Pending : ConvexAuthState;
    /// <summary>The server accepted the token.</summary>
    public sealed record Authenticated : ConvexAuthState;
    /// <summary>The server refused fresh tokens repeatedly. The socket runs without an identity until SetAuth is called again.</summary>
    public sealed record Failed(string Message) : ConvexAuthState;
}

/// <summary>Monotonic milliseconds (unaffected by wall clock changes), like Swift's ContinuousClock.</summary>
public static class MonoClock
{
    public static double NowMs => Stopwatch.GetTimestamp() * 1000.0 / Stopwatch.Frequency;
}

/// <summary>A token as the client keeps it: its text, when to refresh it, and whom it signs in.</summary>
public sealed record AuthToken
{
    public string Value { get; }
    /// <summary>
    /// When to fetch a new one (monotonic ms): <see cref="RefreshLeewayMs"/> before it expires, by its own lifetime
    /// (exp - iat) counted from when it arrived, so a skewed device clock doesn't matter. Null when it carries no lifetime.
    /// </summary>
    public double? RefreshAt { get; }
    /// <summary>Its <c>sub</c> claim (the Clerk user id), null when it doesn't say.</summary>
    public string? Subject { get; }

    public const double RefreshLeewayMs = 10_000;

    public AuthToken(string value, double? receivedAt = null)
    {
        Value = value;
        var claims = JwtClaims.Decode(value);
        Subject = claims?.Sub;
        if (claims is { Exp: { } exp, Iat: { } iat } && exp > iat)
            RefreshAt = (receivedAt ?? MonoClock.NowMs) + Math.Max(0, exp - iat) * 1000 - RefreshLeewayMs;
    }

    public bool NeedsRefresh(double? now = null) => RefreshAt is { } at && (now ?? MonoClock.NowMs) >= at;
}

/// <summary>
/// The exp, iat and sub claims of a JWT (seconds since 1970), decoded WITHOUT checking the signature. Convex verifies
/// every token and is the authorization boundary; <c>sub</c> here is a routing guard only, so a call made for one
/// identity never goes out with a token fetched for another. A forged token passes it and still gets nothing.
/// </summary>
public sealed record JwtClaims(double? Exp, double? Iat, string? Sub)
{
    public static JwtClaims? Decode(string jwt)
    {
        var parts = jwt.Split('.');
        if (parts.Length != 3) return null;
        var payload = Base64Url.TryDecode(parts[1]);
        if (payload is null) return null;
        try
        {
            using var doc = JsonDocument.Parse(payload);
            var o = doc.RootElement;
            if (o.ValueKind != JsonValueKind.Object) return null;
            double? Num(string key) => o.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetDouble() : null;
            var sub = o.TryGetProperty("sub", out var s) && s.ValueKind == JsonValueKind.String ? s.GetString() : null;
            return new JwtClaims(Num("exp"), Num("iat"), sub);
        }
        catch (JsonException) { return null; }
    }
}

/// <summary>base64url without padding, as the Swift client writes tokens and keys.</summary>
public static class Base64Url
{
    public static string Encode(ReadOnlySpan<byte> data) =>
        Convert.ToBase64String(data).Replace('+', '-').Replace('/', '_').TrimEnd('=');

    public static byte[]? TryDecode(string text)
    {
        var s = text.Replace('-', '+').Replace('_', '/');
        while (s.Length % 4 != 0) s += "=";
        try { return Convert.FromBase64String(s); } catch (FormatException) { return null; }
    }

    /// <summary>Standard base64 decode that returns null instead of throwing.</summary>
    public static byte[]? TryDecodeStandard(string? text)
    {
        if (text is null) return null;
        try { return Convert.FromBase64String(text); } catch (FormatException) { return null; }
    }

    internal static string Utf8(byte[] data) => Encoding.UTF8.GetString(data);
}
