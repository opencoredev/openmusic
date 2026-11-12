namespace OpenMusic.Core;

/// <summary>Swift's <c>ProviderError</c> cases.</summary>
public enum ProviderErrorKind { NotSignedIn, NotSupported, NotFound, RateLimited, Unplayable, Network, Decoding, Server }

/// <summary>Port of Swift's <c>ProviderError</c>. Every unsupported provider operation throws
/// <see cref="NotSupported"/>, and <see cref="IMusicProvider.Capabilities"/> says what is supported so the UI can hide it.
/// <see cref="Exception.Message"/> is the Swift <c>errorDescription</c>.</summary>
public sealed class ProviderException : Exception
{
    public ProviderErrorKind Kind { get; }
    /// <summary>The associated text: what isn't supported, why it's unplayable, the network or decoding message.</summary>
    public string? Detail { get; }
    /// <summary>HTTP status for <see cref="ProviderErrorKind.Server"/>.</summary>
    public int? StatusCode { get; }

    private ProviderException(ProviderErrorKind kind, string? detail = null, int? status = null, Exception? inner = null)
        : base(Describe(kind, detail, status), inner)
    {
        Kind = kind;
        Detail = detail;
        StatusCode = status;
    }

    public static ProviderException NotSignedIn() => new(ProviderErrorKind.NotSignedIn);
    public static ProviderException NotSupported(string what) => new(ProviderErrorKind.NotSupported, what);
    public static ProviderException NotFound() => new(ProviderErrorKind.NotFound);
    public static ProviderException RateLimited() => new(ProviderErrorKind.RateLimited);
    public static ProviderException Unplayable(string why) => new(ProviderErrorKind.Unplayable, why);
    public static ProviderException Network(string message, Exception? inner = null) => new(ProviderErrorKind.Network, message, inner: inner);
    public static ProviderException Decoding(string message) => new(ProviderErrorKind.Decoding, message);
    public static ProviderException Server(int status, string message) => new(ProviderErrorKind.Server, message, status);

    private static string Describe(ProviderErrorKind kind, string? detail, int? status) => kind switch
    {
        ProviderErrorKind.NotSignedIn => "Sign in to use this.",
        ProviderErrorKind.NotSupported => $"{detail} isn't supported.",
        ProviderErrorKind.NotFound => "Not found.",
        ProviderErrorKind.RateLimited => "Too many requests. Try again in a moment.",
        ProviderErrorKind.Unplayable => $"Can't play this track: {detail}",
        ProviderErrorKind.Network => $"Network error: {detail}",
        ProviderErrorKind.Decoding => $"Unexpected response: {detail}",
        _ => $"Server error {status}: {detail}",
    };

    public override bool Equals(object? obj) =>
        obj is ProviderException o && o.Kind == Kind && o.Detail == Detail && o.StatusCode == StatusCode;

    public override int GetHashCode() => HashCode.Combine(Kind, Detail, StatusCode);
}

/// <summary>A playlist edit the service can't do exactly, refused before anything was written (Swift's
/// <c>PlaylistEditError</c>).</summary>
public sealed class PlaylistEditException : Exception
{
    /// <summary>Set for <see cref="UnidentifiedCopies"/>: how many copies carry no entry id.</summary>
    public int? UnidentifiedCount { get; }
    public bool IsAccountChanged => UnidentifiedCount is null;

    private PlaylistEditException(int? count, string message) : base(message) => UnidentifiedCount = count;

    /// <summary>Some copies of the songs carry no entry id the service could remove them by (YouTube's <c>setVideoId</c>).</summary>
    public static PlaylistEditException UnidentifiedCopies(int count) =>
        new(count, $"{count} of the copies have no entry id to remove them by.");

    /// <summary>The request wasn't sent: the credentials it would have gone out with belong to another account by now.</summary>
    public static PlaylistEditException AccountChanged() => new(null, "The sign-in changed before the request went out.");
}
