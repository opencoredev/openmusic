using System.Diagnostics;
using System.Text.Json;
using OpenMusic.Sync;
using OpenMusic.Sync.Account;
using OpenMusic.Sync.Convex;
using OpenMusic.Sync.Keys;

namespace OpenMusic.SyncProbe;

/// <summary>
/// openmusic-sync-probe: drives OpenMusic.Sync against a real deployment from a terminal. Every command takes
/// <c>--state &lt;dir&gt;</c>, a 0700 directory holding this probe device's secrets (a FileSecretStore), so two state
/// directories are two devices. Tokens, keys and the test user's email are never printed.
/// </summary>
public static partial class Probe
{
    internal static readonly Stopwatch Clock = Stopwatch.StartNew();
    internal static string Name = "probe";

    internal static void Log(string message)
    {
        Console.WriteLine($"[{Name} +{Clock.Elapsed.TotalSeconds,7:F3}s] {message}");
        Console.Out.Flush();
    }

    public static async Task<int> Main(string[] args)
    {
        if (args.Length == 0) return Usage();
        var options = new Options(args.Skip(1).ToArray());
        Name = options.Value("--name") ?? "probe";
        try
        {
            return args[0] switch
            {
                "clerk" => await ClerkCommand(options),
                "jwt-file" => await JwtFileCommand(options),
                "oauth-url" => await OAuthUrlCommand(options),
                _ => await SyncCommand(args[0], options),
            };
        }
        catch (Exception e)
        {
            Log($"FAILED: {e.GetType().Name}: {e.Message}");
            return 1;
        }
    }

    private static int Usage()
    {
        Console.WriteLine("""
            usage: openmusic-sync-probe <command> --state <dir> [--name N] [--url <deployment>]
              clerk                      sign in to Clerk as the test user (email code), print the user id and JWT lifetime
              oauth-url <apple|google>   start a social sign-in (fresh client, nothing saved) and print where the browser would go
              jwt-file --out <path> [--seconds N] [--remote <ssh-host:path>]
                                         keep a fresh Convex JWT in <path> (0600) for a Swift probe's --jwt-file
              sign-in | sign-out | devices | keys | allow <device|all> | confirm | watch | run --script "..."
                run --play [--track "<videoId>|<title>|<artist>|<seconds>"]   play a real YouTube song id (silently)
                step signin-ytm <name>: a fake YouTube Music sign-in in the YouTube payload format (MEDLEY_TEST_SIGNIN)
            """);
        return 2;
    }

    internal sealed class Options
    {
        private readonly Dictionary<string, string> _named = new();
        private readonly HashSet<string> _flags = new();
        public List<string> Positional { get; } = new();
        private static readonly HashSet<string> Valued = ["--state", "--name", "--url", "--seconds", "--out", "--remote", "--script", "--to", "--from", "--user-file", "--track", "--platform"];

        public Options(string[] args)
        {
            for (var i = 0; i < args.Length; i++)
            {
                if (Valued.Contains(args[i]) && i + 1 < args.Length) _named[args[i]] = args[++i];
                else if (args[i].StartsWith("--", StringComparison.Ordinal)) _flags.Add(args[i]);
                else Positional.Add(args[i]);
            }
        }

        public string? Value(string key) => _named.GetValueOrDefault(key);
        public bool Flag(string key) => _flags.Contains(key);
        public string State => Value("--state") ?? throw new ArgumentException("--state <dir> is required");
    }

    internal const string PublishableKey = "pk_test_aGVscGVkLXRlcnJpZXItNTMzOS5jbGVyay5hY2NvdW50cy5kZXYk";
    internal static readonly Uri DevDeployment = SyncService.DefaultDeploymentUrl;

    /// <summary>The test user's email, read from a 0600 file and never printed. Its code is always 424242 (+clerk_test).</summary>
    internal static string TestUserEmail(Options options)
    {
        var path = options.Value("--user-file") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config/openmusic/clerk-test-user.json");
        using var doc = JsonDocument.Parse(File.ReadAllText(path));
        return doc.RootElement.GetProperty("email").GetString()!;
    }

    /// <summary>A Clerk client for the probe's state directory, signed in as the test user (email code) when it isn't yet.</summary>
    internal static async Task<ClerkClient> SignedInClerk(Options options, SyncCredentialStore store)
    {
        var clerk = new ClerkClient(PublishableKey, new CredentialClerkStateStore(store));
        var sw = Stopwatch.StartNew();
        if (clerk.SavedSession is not null && await clerk.RestoreAsync() is { } restored)
        {
            Log($"clerk: restored session for {restored.User.Id} in {sw.ElapsedMilliseconds} ms");
            return clerk;
        }
        var challenge = await clerk.StartEmailAsync(TestUserEmail(options));
        Log($"clerk: email code sent ({challenge.Kind}) in {sw.ElapsedMilliseconds} ms");
        var session = await clerk.VerifyEmailAsync(challenge, "424242");
        Log($"clerk: signed in as {session.User.Id} ({session.User.DisplayName.Length} chars of name) in {sw.ElapsedMilliseconds} ms");
        return clerk;
    }

    private static async Task<int> ClerkCommand(Options options)
    {
        var store = new SyncCredentialStore(new FileSecretStore(options.State));
        var clerk = await SignedInClerk(options, store);
        var sw = Stopwatch.StartNew();
        var jwt = await clerk.GetTokenAsync(forceRefresh: true) ?? throw new InvalidOperationException("no token");
        var claims = JwtClaims.Decode(jwt)!;
        Log($"convex token: sub {claims.Sub}, lifetime {claims.Exp - claims.Iat} s, fetched in {sw.ElapsedMilliseconds} ms");
        var cached = await clerk.GetTokenAsync(forceRefresh: false);
        Log($"cached token reused: {cached == jwt}");
        var providers = await clerk.SocialProvidersAsync();
        Log($"social sign-ins on: {string.Join(", ", providers.Select(p => p.Name))}");
        if (options.Flag("--sign-out"))
        {
            await clerk.SignOutAsync();
            Log($"signed out; token now {(await clerk.GetTokenAsync(true) is null ? "null" : "still there")}");
        }
        return 0;
    }

    /// <summary>Starts a social sign-in on a throwaway client and prints the sign-in page's host and path (not its query,
    /// which carries the attempt's state). Checks that the Clerk app hands out that provider's page.</summary>
    private static async Task<int> OAuthUrlCommand(Options options)
    {
        var provider = options.Positional.FirstOrDefault() switch { "apple" => ClerkOAuthProvider.Apple, _ => ClerkOAuthProvider.Google };
        var clerk = new ClerkClient(PublishableKey, new MemoryClerkStateStore());
        var providers = await clerk.SocialProvidersAsync();
        Log($"social sign-ins on: {string.Join(", ", providers.Select(p => p.Name))}");
        var start = await clerk.StartOAuthAsync(provider);
        Log($"{provider.Name}: browser goes to {start.Url.Scheme}://{start.Url.Host}{start.Url.AbsolutePath} (sign-in {start.SignInId[..Math.Min(8, start.SignInId.Length)]}…)");
        try
        {
            await clerk.CompleteOAuthAsync(start, new Uri(ClerkClient.OAuthRedirect));
            Log("callback before the browser: completed (unexpected)");
        }
        catch (ClerkException e)
        {
            Log($"callback before the browser finished: {e.Kind}");
        }
        return 0;
    }

    /// <summary>Keeps a fresh JWT in a 0600 file (and optionally copies it to a remote path over ssh) for --seconds.</summary>
    private static async Task<int> JwtFileCommand(Options options)
    {
        var store = new SyncCredentialStore(new FileSecretStore(options.State));
        var clerk = await SignedInClerk(options, store);
        var output = options.Value("--out") ?? throw new ArgumentException("--out <path>");
        var remote = options.Value("--remote");
        var until = Clock.Elapsed + TimeSpan.FromSeconds(double.Parse(options.Value("--seconds") ?? "600"));
        while (Clock.Elapsed < until)
        {
            var jwt = await clerk.GetTokenAsync(forceRefresh: true) ?? throw new InvalidOperationException("signed out");
            var fileOptions = new FileStreamOptions { Mode = FileMode.Create, Access = FileAccess.Write, UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite };
            await using (var f = new FileStream(output + ".tmp", fileOptions)) await f.WriteAsync(System.Text.Encoding.UTF8.GetBytes(jwt));
            File.Move(output + ".tmp", output, true);
            if (remote is not null)
            {
                var (host, path) = (remote[..remote.IndexOf(':')], remote[(remote.IndexOf(':') + 1)..]);
                using var p = Process.Start(new ProcessStartInfo("ssh", ["-o", "BatchMode=yes", host, $"umask 077 && cat > {path}.tmp && mv {path}.tmp {path}"])
                    { RedirectStandardInput = true })!;
                await p.StandardInput.WriteAsync(jwt);
                p.StandardInput.Close();
                await p.WaitForExitAsync();
            }
            var claims = JwtClaims.Decode(jwt)!;
            var lifetime = (claims.Exp - claims.Iat) ?? 60;
            await Task.Delay(TimeSpan.FromSeconds(Math.Max(5, lifetime - 20)));
        }
        return 0;
    }
}

/// <summary>A Clerk state that lives only as long as the probe process (oauth-url saves nothing).</summary>
internal sealed class MemoryClerkStateStore : IClerkStateStore
{
    private ClerkState? _state;
    public ClerkState? Load() => _state;
    public void Save(ClerkState? state) => _state = state;
}
