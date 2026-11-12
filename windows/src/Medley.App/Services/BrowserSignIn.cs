using System.Threading.Channels;
using Medley.Sync.Account;

namespace Medley.App.Services;

/// <summary>
/// "Continue with Apple" and "Continue with Google": Clerk's sign-in page in the system browser, which comes back as an
/// <c>openmusic://oauth-callback</c> link (a second launch, handed to this instance by <see cref="Program"/>).
/// <para>One sign-in waits at a time; starting another cancels the one before. A link that comes when nothing waits (the
/// listener cancelled, or the page was finished twice) is ignored. A link that comes while a sign-in waits but isn't its
/// answer (Clerk says the browser hasn't finished: an earlier attempt's link) is skipped and the sign-in keeps waiting.
/// UI thread only.</para>
/// </summary>
public static class BrowserSignIn
{
    private sealed class Pending
    {
        public Channel<Uri> Links { get; } = Channel.CreateUnbounded<Uri>();
    }

    private static Pending? _pending;
    private static Uri? _page;
    private static CancellationTokenSource? _cancel;

    /// <summary>Whether a browser sign-in is waiting for its link (not yet finishing it).</summary>
    public static bool IsWaiting => _pending is not null && !_completing;

    /// <summary>The browser answered and Clerk is finishing the sign-in: too late to cancel (it would leave the account
    /// half changed), so Cancel does nothing meanwhile.</summary>
    private static bool _completing;

    /// <summary>The browser's link came back (from <see cref="ShellPage.HandleLink"/>). True when it was a sign-in link.</summary>
    public static bool HandleCallback(Uri link)
    {
        if (!link.Host.Equals("oauth-callback", StringComparison.OrdinalIgnoreCase)) return false;
        if (_pending is not { } pending)
        {
            Log.Info("sign-in: a browser sign-in link came back with no sign-in waiting; ignored");
            return true;
        }
        pending.Links.Writer.TryWrite(link);
        return true;
    }

    /// <summary>Opens the waiting sign-in's page again (the listener closed the browser). False when nothing waits.</summary>
    public static async Task<bool> ReopenAsync()
    {
        if (_pending is null || _page is not { } page) return false;
        Log.Info("sign-in: page opened again");
        return await Windows.System.Launcher.LaunchUriAsync(page);
    }

    /// <summary>Stops the sign-in that waits for the browser, if any (Cancel, Esc, leaving the screen).</summary>
    public static void Cancel()
    {
        if (!_completing) _cancel?.Cancel();
    }

    /// <summary>Raised when the browser's answer came back and the sign-in is being finished (Cancel no longer applies).</summary>
    public static event Action? Completing;

    /// <summary>
    /// Opens the provider's sign-in page in the browser and waits for it (ten minutes at most). <paramref name="opened"/> runs
    /// once the browser has the page. Throws OperationCanceledException when cancelled, ClerkException when Clerk refused.
    /// </summary>
    public static async Task<ClerkUser> RunAsync(AccountService account, ClerkOAuthProvider provider, Action? opened = null)
    {
        Cancel();
        var cancel = new CancellationTokenSource(TimeSpan.FromMinutes(10));
        _cancel = cancel;
        var pending = new Pending();
        try
        {
            var start = await account.StartOAuthAsync(provider);
            cancel.Token.ThrowIfCancellationRequested();
            _pending = pending;
            _page = start.Url;
            if (!await Windows.System.Launcher.LaunchUriAsync(start.Url))
                throw new InvalidOperationException("Windows couldn't open your browser.");
            Log.Info($"sign-in: {provider.Name} page opened in the browser");
            opened?.Invoke();
            while (true)
            {
                var link = await pending.Links.Reader.ReadAsync(cancel.Token);
                try
                {
                    _completing = true;
                    Completing?.Invoke();
                    var user = await account.CompleteOAuthAsync(start, link);
                    Log.Info($"sign-in: {provider.Name} sign-in finished");
                    return user;
                }
                catch (ClerkException e) when (e.Kind == ClerkErrorKind.NotFinished)
                {
                    _completing = false;
                    // An earlier attempt's link: this sign-in still waits for its own.
                    Log.Info($"sign-in: a link that isn't this {provider.Name} sign-in's answer came back; still waiting");
                }
            }
        }
        finally
        {
            if (ReferenceEquals(_pending, pending))
            {
                _pending = null;
                _page = null;
                _completing = false;
            }
            if (ReferenceEquals(_cancel, cancel)) _cancel = null;
            cancel.Dispose();
        }
    }

    /// <summary>What to show for a failed sign-in: null when there's nothing to say (cancelled here, or superseded).</summary>
    public static string? Describe(Exception e, ClerkOAuthProvider? provider = null) => e switch
    {
        OperationCanceledException => null,
        ClerkException { Kind: ClerkErrorKind.Stale } => null,
        ClerkException { Kind: ClerkErrorKind.Refused, Code: { } code } when provider is not null && code.Contains("access_denied", StringComparison.Ordinal) =>
            $"Signing in with {provider.Name} was cancelled. Try again, or use your email.",
        ClerkException { Kind: ClerkErrorKind.Network } or ServerException { Kind: ServerErrorKind.Unreachable } =>
            $"{Medley.Core.ProductInfo.Name} can't reach the sign-in service. Check your connection and try again.",
        _ => Log.Redact(e.Message.Split('\n', 2)[0]),
    };
}
