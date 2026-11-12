using OpenMusic.Core;
using OpenMusic.Sync.Convex;

namespace OpenMusic.Sync;

public enum SyncErrorKind
{
    /// <summary>Not signed in to an account on this device (or not registered yet).</summary>
    NotPaired,
    /// <summary>The sync server needs a sign-in: the Clerk session ended or its token was refused.</summary>
    NotSignedIn,
    /// <summary>This device was removed from the account's devices. The app signs out.</summary>
    RemovedFromLibrary,
    SignInTransferFailed,
    /// <summary>The vault key this device holds isn't the account's.</summary>
    LibraryKeyMismatch,
    KeyGrantFailed,
    UnknownDevice,
    DeviceOffline,
    NothingPlaying,
    ProviderUnavailable,
    PlaybackFailed,
    CommandFailed,
    TimedOut,
    /// <summary>Moving playback needs the account's sign-in key on both devices (what plays is sealed with it). The
    /// detail names the device that lacks it; null means this one.</summary>
    NeedsKey,
    Server,
    Network,
    /// <summary>
    /// The account, server or sign-in changed while this was in progress, so it was dropped: nothing of it reached the
    /// account that is signed in now.
    /// </summary>
    AuthChanged,
}

/// <summary>Everything sync reports to the UI. Messages are written to be shown as they are (same text as the Swift apps).</summary>
public sealed class SyncException : Exception, IEquatable<SyncException>
{
    public SyncErrorKind Kind { get; }
    public string? Detail { get; }
    public ProviderId? Provider { get; }

    /// <param name="detail">Cleaned like any server text (<see cref="ServerText"/>): a detail can carry a server's error.</param>
    public SyncException(SyncErrorKind kind, string? detail = null, ProviderId? provider = null) : base(Describe(kind, Clean(detail), provider))
    {
        Kind = kind; Detail = Clean(detail); Provider = provider;
    }

    private static string? Clean(string? detail) => detail is null ? null : ServerText.Clean(detail);

    public static SyncException NotPaired => new(SyncErrorKind.NotPaired);
    public static SyncException NotSignedIn => new(SyncErrorKind.NotSignedIn);
    public static SyncException RemovedFromLibrary => new(SyncErrorKind.RemovedFromLibrary);
    public static SyncException LibraryKeyMismatch => new(SyncErrorKind.LibraryKeyMismatch);
    public static SyncException UnknownDevice => new(SyncErrorKind.UnknownDevice);
    public static SyncException SignInTransferFailed(string why) => new(SyncErrorKind.SignInTransferFailed, why);
    public static SyncException KeyGrantFailed(string why) => new(SyncErrorKind.KeyGrantFailed, why);
    public static SyncException DeviceOffline(string name) => new(SyncErrorKind.DeviceOffline, name);
    public static SyncException NothingPlaying(string name) => new(SyncErrorKind.NothingPlaying, name);
    public static SyncException ProviderUnavailable(ProviderId provider, string? deviceName) => new(SyncErrorKind.ProviderUnavailable, deviceName, provider);
    public static SyncException PlaybackFailed(string why) => new(SyncErrorKind.PlaybackFailed, why);
    public static SyncException CommandFailed(string why) => new(SyncErrorKind.CommandFailed, why);
    public static SyncException TimedOut(string what) => new(SyncErrorKind.TimedOut, what);
    public static SyncException NeedsKey(string? device) => new(SyncErrorKind.NeedsKey, device);
    public static SyncException Server(string why) => new(SyncErrorKind.Server, why);
    public static SyncException Network(string why) => new(SyncErrorKind.Network, why);
    public static SyncException AuthChanged => new(SyncErrorKind.AuthChanged);

    private static string Describe(SyncErrorKind kind, string? d, ProviderId? provider) => kind switch
    {
        SyncErrorKind.NotPaired => "Sign in to sync this device with your others.",
        SyncErrorKind.NotSignedIn => "Your sign-in expired. Sign in again to sync.",
        SyncErrorKind.RemovedFromLibrary => "This device was removed from your devices. Sign in again to sync.",
        SyncErrorKind.SignInTransferFailed => $"Your sign-ins couldn't be synced: {d}.",
        SyncErrorKind.LibraryKeyMismatch => "This device's sign-in key isn't your account's.",
        SyncErrorKind.KeyGrantFailed => $"Your sign-ins couldn't be shared with this device: {d}.",
        SyncErrorKind.UnknownDevice => "That device isn't in your devices any more.",
        SyncErrorKind.DeviceOffline => $"{d} isn't online.",
        SyncErrorKind.NothingPlaying => $"Nothing is playing on {d}.",
        SyncErrorKind.ProviderUnavailable => d is not null
            ? $"{provider?.DisplayName()} isn't signed in on {d}."
            : $"{provider?.DisplayName()} isn't signed in on this device.",
        SyncErrorKind.PlaybackFailed => $"Couldn't start playback: {d}",
        SyncErrorKind.TimedOut => $"{d} didn't respond in time.",
        SyncErrorKind.NeedsKey => d is not null
            ? $"{d} doesn't have your sign-in key yet, so it can't take over playback. Allow it on a device that has your sign-ins first."
            : "This device doesn't have your sign-in key yet, so it can't see or continue what plays elsewhere. Allow it on a device that has your sign-ins first.",
        SyncErrorKind.AuthChanged => $"Your sign-in changed while that was in progress, so {ProductInfo.Name} stopped it.",
        _ => d ?? "",
    };

    /// <summary>Maps any error to what the UI shows, the way <c>SyncError.from</c> does.</summary>
    public static SyncException From(Exception error)
    {
        if (error is SyncException sync) return sync;
        if (error is ConvexClientException convex)
        {
            switch (convex.Code)
            {
                case "unauthorized": return RemovedFromLibrary;
                case "unauthenticated": return NotSignedIn;
                case "notFound": return UnknownDevice;
            }
            if (convex.Kind == ConvexErrorKind.AuthChanged) return AuthChanged;
            return convex.Kind is ConvexErrorKind.Transport or ConvexErrorKind.Stopped
                ? Network(convex.Message)
                : Server(convex.Message);
        }
        return Network(error.Message);
    }

    public bool Equals(SyncException? other) => other is not null && Kind == other.Kind && Detail == other.Detail && Provider == other.Provider;
    public override bool Equals(object? obj) => obj is SyncException e && Equals(e);
    public override int GetHashCode() => HashCode.Combine(Kind, Detail, Provider);
}
