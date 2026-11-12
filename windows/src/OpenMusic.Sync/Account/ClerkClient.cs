using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using OpenMusic.Core;
using OpenMusic.Sync.Convex;
using OpenMusic.Sync.Keys;

namespace OpenMusic.Sync.Account;

// Clerk's Frontend API in native mode, the way the official SDKs speak it, without an SDK (docs/accounts-design.md,
// "Clerk on native"). Every request carries `_is_native=true` and the saved client token in `Authorization` (no cookies,
// no Origin); every response's `Authorization` header replaces the saved token.

public sealed record ClerkRequest(string Method, Uri Url, IReadOnlyDictionary<string, string> Headers, byte[]? Body);
public sealed record ClerkResponse(int Status, byte[] Body, string? Authorization);

/// <summary>Sends one request. HttpClient in the app; a fake in tests.</summary>
public interface IClerkHttp
{
    Task<ClerkResponse> SendAsync(ClerkRequest request, CancellationToken cancellationToken = default);
}

/// <summary>No cookies, 20 s timeout.</summary>
public sealed class HttpClientClerkHttp : IClerkHttp
{
    private readonly HttpClient _client = new(new SocketsHttpHandler { UseCookies = false, AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(20) };

    public async Task<ClerkResponse> SendAsync(ClerkRequest request, CancellationToken cancellationToken = default)
    {
        using var message = new HttpRequestMessage(new HttpMethod(request.Method), request.Url);
        if (request.Body is not null) message.Content = new ByteArrayContent(request.Body);
        foreach (var (key, value) in request.Headers)
        {
            if (key.Equals("Content-Type", StringComparison.OrdinalIgnoreCase))
            {
                message.Content ??= new ByteArrayContent([]);
                message.Content.Headers.ContentType = MediaTypeHeaderValue.Parse(value);
            }
            else message.Headers.TryAddWithoutValidation(key, value);
        }
        using var response = await _client.SendAsync(message, cancellationToken).ConfigureAwait(false);
        var body = await response.Content.ReadAsByteArrayAsync(cancellationToken).ConfigureAwait(false);
        var auth = response.Headers.TryGetValues("Authorization", out var values) ? values.FirstOrDefault() : null;
        return new ClerkResponse((int)response.StatusCode, body, auth);
    }
}

public enum ClerkErrorKind { Refused, UnsupportedRequirements, NotConfigured, SessionEnded, Network, Unexpected, Stale, OriginChanged, OtherSessionNotAdopted, NotFinished }

/// <summary>What the sign-in flows report. Messages are meant to be shown (same text as the Swift apps).</summary>
public sealed class ClerkException : Exception
{
    public ClerkErrorKind Kind { get; }
    public string? Code { get; }
    public string Detail { get; }
    public IReadOnlyList<string> Fields { get; }

    private ClerkException(ClerkErrorKind kind, string detail, string? code = null, IReadOnlyList<string>? fields = null)
        : base(Describe(kind, detail, fields))
    {
        Kind = kind; Detail = detail; Code = code; Fields = fields ?? [];
    }

    public static ClerkException Refused(string code, string message) => new(ClerkErrorKind.Refused, message, code);
    public static ClerkException UnsupportedRequirements(IReadOnlyList<string> fields) => new(ClerkErrorKind.UnsupportedRequirements, "", fields: fields);
    public static ClerkException NotConfigured() => new(ClerkErrorKind.NotConfigured, "");
    public static ClerkException SessionEnded() => new(ClerkErrorKind.SessionEnded, "");
    public static ClerkException Network(string why) => new(ClerkErrorKind.Network, why);
    public static ClerkException Unexpected(string why) => new(ClerkErrorKind.Unexpected, why);
    public static ClerkException Stale() => new(ClerkErrorKind.Stale, "");
    public static ClerkException OriginChanged(string host) => new(ClerkErrorKind.OriginChanged, host);
    public static ClerkException OtherSessionNotAdopted(string name) => new(ClerkErrorKind.OtherSessionNotAdopted, name);
    /// <summary>A social sign-in's callback came while that sign-in still waits for the browser: the link belongs to an
    /// earlier attempt (cancelled, or opened twice). Nothing changed; keep waiting for this attempt's callback.</summary>
    public static ClerkException NotFinished() => new(ClerkErrorKind.NotFinished, "");

    private static string Describe(ClerkErrorKind kind, string d, IReadOnlyList<string>? fields) => kind switch
    {
        ClerkErrorKind.Refused => d,
        ClerkErrorKind.UnsupportedRequirements =>
            $"This server's sign-in also asks for {string.Join(", ", fields ?? [])}, which {ProductInfo.Name} doesn't support. Its Clerk app should ask only for an email address.",
        ClerkErrorKind.NotConfigured => "This server isn't set up for sign-in yet.",
        ClerkErrorKind.SessionEnded => "You were signed out. Sign in again.",
        ClerkErrorKind.Network => $"Can't reach the sign-in service: {d}",
        ClerkErrorKind.Unexpected => $"Sign-in failed: {d}",
        ClerkErrorKind.Stale => "You signed out while that was in progress.",
        ClerkErrorKind.NotFinished => "Finish signing in in your browser.",
        ClerkErrorKind.OriginChanged =>
            $"This server now signs in through a different service ({d}), so {ProductInfo.Name} signed you out instead of sending your sign-in there. Sign in again only if you trust this server.",
        _ => $"Your sign-in on this device ended. {ProductInfo.Name} signed you out instead of switching to another sign-in it found ({d}). Sign in again to choose the account.",
    };
}

/// <summary>The signed-in Clerk user, as the apps show them. Never sent to the sync server.</summary>
public sealed record ClerkUser(string Id, string? FirstName = null, string? LastName = null, string? Email = null, string? ImageUrl = null)
{
    /// <summary>"Riley Smith", else the email address, else "Signed in".</summary>
    public string DisplayName
    {
        get
        {
            var name = string.Join(" ", new[] { FirstName, LastName }.Select(s => s?.Trim()).Where(s => !string.IsNullOrEmpty(s)));
            return name.Length > 0 ? name : Email ?? "Signed in";
        }
    }
}

public sealed record ClerkSession(string Id, ClerkUser User);

/// <summary>A session that ended on Clerk's side, with who it was, so the app ends that sign-in only.</summary>
public sealed record ClerkSessionEnd(string SessionId, string? UserId, ClerkUser? NotAdopted = null);

public sealed record ClerkOAuthProvider(string Strategy)
{
    public static readonly ClerkOAuthProvider Google = new("oauth_google");
    public static readonly ClerkOAuthProvider Apple = new("oauth_apple");
    public string Name => Strategy switch
    {
        "oauth_google" => "Google",
        "oauth_apple" => "Apple",
        "oauth_github" => "GitHub",
        "oauth_microsoft" => "Microsoft",
        _ => System.Globalization.CultureInfo.InvariantCulture.TextInfo.ToTitleCase(Strategy.StartsWith("oauth_", StringComparison.Ordinal) ? Strategy[6..] : Strategy),
    };
}

public enum ClerkChallengeKind { SignIn, SignUp }
/// <summary>An email code on its way: which attempt to complete with the code.</summary>
public sealed record ClerkEmailChallenge(ClerkChallengeKind Kind, string AttemptId, string Email);
/// <summary>A social sign-in waiting for the browser: open <see cref="Url"/>, then pass the <c>openmusic://oauth-callback</c> URL to CompleteOAuth.</summary>
public sealed record ClerkOAuthStart(Uri Url, string SignInId);

/// <summary>The persisted part of a Clerk sign-in, bound to the Frontend API origin it was made with.</summary>
public sealed record ClerkState
{
    public string? FrontendApi { get; init; }
    public string? ClientToken { get; init; }
    public string? SessionId { get; init; }
    public ClerkUser? User { get; init; }
    internal bool HoldsCredentials => ClientToken is not null || SessionId is not null;
    public override string ToString() => $"ClerkState(frontendAPI: {FrontendApi ?? "none"}, session: {SessionId ?? "none"}, user: {User?.Id ?? "none"}, clientToken: <redacted>)";
}

public interface IClerkStateStore
{
    ClerkState? Load();
    void Save(ClerkState? state);
}

/// <summary><see cref="ClerkState"/> inside the sync credential store (<c>sync.credentials.state.clerk</c>).</summary>
public sealed class CredentialClerkStateStore(SyncCredentialStore store, string name = "clerk") : IClerkStateStore
{
    public ClerkState? Load() => store.StateAs<ClerkState>(name);
    public void Save(ClerkState? state) => store.SetState(name, state is null ? null : SyncCredentialStore.Encode(state));
}

/// <summary>The publishable key names the Frontend API host: <c>pk_test_</c> or <c>pk_live_</c> + base64("&lt;host&gt;$").</summary>
public static class ClerkPublishableKey
{
    /// <summary><c>https://&lt;host&gt;</c> for a well-formed key naming a plausible public DNS name, else null.</summary>
    public static Uri? FrontendApi(string key)
    {
        string body;
        if (key.StartsWith("pk_test_", StringComparison.Ordinal) || key.StartsWith("pk_live_", StringComparison.Ordinal)) body = key[8..];
        else return null;
        while (body.Length % 4 != 0) body += "=";
        string decoded;
        try { decoded = Encoding.UTF8.GetString(Convert.FromBase64String(body)); }
        catch (FormatException) { return null; }
        if (!decoded.EndsWith('$')) return null;
        var host = decoded[..^1];
        if (!IsPlausibleHost(host)) return null;
        return Uri.TryCreate($"https://{host}", UriKind.Absolute, out var url) && url.Host == host && url.IsDefaultPort && url.AbsolutePath == "/" && url.Query.Length == 0
            ? url : null;
    }

    /// <summary>A lowercase DNS name with at least two labels: letters, digits and inner hyphens; no IP, port or localhost.</summary>
    public static bool IsPlausibleHost(string host)
    {
        if (host.Length is < 4 or > 253 || host != host.ToLowerInvariant()) return false;
        var labels = host.Split('.');
        if (labels.Length < 2) return false;
        foreach (var label in labels)
        {
            if (label.Length is < 1 or > 63 || label[0] == '-' || label[^1] == '-') return false;
            if (!label.All(c => c is >= 'a' and <= 'z' or >= '0' and <= '9' or '-')) return false;
        }
        if (!labels[^1].Any(c => c is >= 'a' and <= 'z')) return false;
        return !host.EndsWith(".localhost", StringComparison.Ordinal) && !host.EndsWith(".local", StringComparison.Ordinal);
    }

    /// <summary>The origin string the state is bound to, as Swift's <c>URL.absoluteString</c> writes it.</summary>
    public static string Origin(Uri frontendApi) => $"https://{frontendApi.Host}";
}

/// <summary>
/// One Clerk instance (one publishable key). Thread-safe and reentrant across awaits; it serves the Convex client's token
/// refreshes from the socket's threads, so its serialization point is its lock rather than the sync actor: every public
/// method takes the lock before it reads or changes state. Every operation captures the session generation it starts in
/// (its ticket) before its first await, and every effect (adopting a session, ending one, keeping a client token, caching a
/// token) checks that generation under the same lock it changes state in. Sign-out, an ended session and a new sign-in
/// start a new generation, and work of an older one is dropped (<see cref="ClerkErrorKind.Stale"/>): a sign-out always wins
/// over a restore, refresh or sign-in in flight, and of two sign-ins the first to finish wins.
/// </summary>
public sealed class ClerkClient : IAuthTokenProvider
{
    public Uri FrontendApi { get; }
    /// <summary>True when saved state belonged to another Frontend API origin and was dropped unused.</summary>
    public bool DiscardedStateForOtherOrigin { get; }

    private readonly IClerkHttp _http;
    private readonly IClerkStateStore _store;
    private readonly object _lock = new();
    private ClerkState _state;
    private AuthToken? _cachedToken;
    private int _generation;
    private JsonObject? _lastClient;
    private Action<ClerkSessionEnd>? _onSessionEnded;
    /// <summary>Retired by a server switch: the store belongs to the next server's client now.</summary>
    private bool _retired;

    /// <summary>Debug builds: state changes only under the lock.</summary>
    [System.Diagnostics.Conditional("DEBUG")]
    private void AssertLocked()
    {
        if (!Monitor.IsEntered(_lock)) throw new InvalidOperationException("Clerk state changed outside its lock");
    }

    /// <summary>The ticket of an operation starting now.</summary>
    private int CurrentGeneration() { lock (_lock) return _generation; }

    /// <summary>
    /// A sign-in flow's ticket: the generation it started in, and the client token its requests last went out or came back
    /// with. A stale flow ends the session it made at Clerk with that token, never with whatever the state holds by then
    /// (a sign-out clears it).
    /// </summary>
    private sealed class Flow(int generation)
    {
        public int Generation { get; } = generation;
        public string? Token { get; set; }
    }

    private Flow StartFlow()
    {
        lock (_lock) return new Flow(_generation) { Token = _state.ClientToken };
    }

    /// <summary>The Convex JWT template.</summary>
    public const string TokenTemplate = "convex";
    /// <summary>The redirect for social sign-ins. The Windows app registers the <c>openmusic:</c> scheme and hands the callback to CompleteOAuth.</summary>
    public const string OAuthRedirect = $"{ProductInfo.UrlScheme}://oauth-callback";
    /// <summary>The Frontend API version the Swift client pins.</summary>
    public const string ApiVersion = "2026-08-20";

    public ClerkClient(string publishableKey, IClerkStateStore store, IClerkHttp? http = null)
    {
        FrontendApi = ClerkPublishableKey.FrontendApi(publishableKey) ?? throw ClerkException.NotConfigured();
        _http = http ?? new HttpClientClerkHttp();
        _store = store;
        var origin = ClerkPublishableKey.Origin(FrontendApi);
        var saved = store.Load();
        if (saved is not null && saved.HoldsCredentials && saved.FrontendApi != origin)
        {
            // Saved for another Clerk host (or before origins were recorded): never sent here. Signed out.
            store.Save(null);
            DiscardedStateForOtherOrigin = true;
            _state = new ClerkState { FrontendApi = origin };
        }
        else
        {
            _state = (saved ?? new ClerkState()) with { FrontendApi = origin };
        }
    }

    public void SetOnSessionEnded(Action<ClerkSessionEnd>? handler) { lock (_lock) _onSessionEnded = handler; }

    /// <summary>The session saved by the last sign-in, with its user, without asking Clerk.</summary>
    public ClerkSession? SavedSession
    {
        get { lock (_lock) return _state.SessionId is { } id && _state.User is { } user ? new ClerkSession(id, user) : null; }
    }

    public ClerkUser? SavedUser => SavedSession?.User;

    /// <summary>The session this client speaks for now (null when signed out).</summary>
    public string? CurrentSessionId { get { lock (_lock) return _state.SessionId; } }

    // MARK: Session

    /// <summary>
    /// Asks Clerk whether the saved session is still active, refreshing its user. Null when signed out. Throws Network when
    /// Clerk can't be reached. Only the saved session counts: never moves to another active one (the end names it).
    /// </summary>
    public async Task<ClerkSession?> RestoreAsync(CancellationToken cancellationToken = default)
    {
        string? saved;
        int generation;
        lock (_lock)
        {
            saved = _state.SessionId;
            if (saved is null) return null;
            if (_state.ClientToken is null) { EndSession(null); return null; }
            generation = _generation;
        }
        // Sent and judged in the generation the saved session was read in: an answer about it never ends a newer one.
        var obj = await RequestAsync("GET", "/v1/client", generation: generation, cancellationToken: cancellationToken).ConfigureAwait(false);
        var client = obj["response"] as JsonObject ?? obj["client"] as JsonObject;
        var session = client is null ? null : ActiveSession(client, saved);
        lock (_lock)
        {
            if (generation != _generation) throw ClerkException.Stale();
            if (session is null)
            {
                EndSession(client is null ? null : ActiveSessions(client).FirstOrDefault()?.User);
                return null;
            }
            _state = _state with { User = session.User };
            Save();
            return session;
        }
    }

    /// <summary>The social sign-ins the Clerk app has on (<c>GET /v1/environment</c>), Apple first, then Google.</summary>
    public async Task<IReadOnlyList<ClerkOAuthProvider>> SocialProvidersAsync(CancellationToken cancellationToken = default)
    {
        var generation = CurrentGeneration();
        var env = await RequestAsync("GET", "/v1/environment", generation: generation, cancellationToken: cancellationToken).ConfigureAwait(false);
        if (env["user_settings"]?["social"] is not JsonObject social) return [];
        string[] preferred = ["oauth_apple", "oauth_google"];
        return social
            .Where(kv => kv.Value is JsonObject c && c["enabled"]?.GetValueKind() == JsonValueKind.True
                         && c["authenticatable"]?.GetValueKind() != JsonValueKind.False)
            .Select(kv => new ClerkOAuthProvider(kv.Key))
            .OrderBy(p => Array.IndexOf(preferred, p.Strategy) is var i && i >= 0 ? i : 99).ThenBy(p => p.Strategy, StringComparer.Ordinal)
            .ToList();
    }

    /// <summary>SignOut, only if the session is still <paramref name="session"/>. The check and forgetting happen together.</summary>
    public async Task<bool> SignOutAsync(string? session)
    {
        if (BeginSignOut(session) is not { } removal) return false;
        await removal.ConfigureAwait(false);
        return true;
    }

    /// <summary>
    /// The synchronous half of <see cref="SignOutAsync(string?)"/>: when the session is still <paramref name="session"/>,
    /// forgets it here before returning, and returns the removal at Clerk to await. Null when it isn't (nothing changed).
    /// </summary>
    internal Task? BeginSignOut(string? session)
    {
        string? id, token;
        lock (_lock)
        {
            if (_state.SessionId != session) return null;
            (id, token) = ForgetForSignOut();
        }
        return RemoveAtClerkAsync(id, token);
    }

    /// <summary>Forgets the session here at once (and saves that), then ends it at Clerk (best effort, with the token it had).</summary>
    public Task SignOutAsync() => BeginSignOut();

    /// <summary>
    /// For a server switch: forgets the session here (saved), then never touches the store again, whatever is still in
    /// flight; the returned task ends the session at Clerk.
    /// </summary>
    internal Task Retire()
    {
        string? id, token;
        lock (_lock)
        {
            (id, token) = ForgetForSignOut();
            _retired = true;
        }
        return RemoveAtClerkAsync(id, token);
    }

    /// <summary>Forgets whatever session there is here before returning; the returned task ends it at Clerk.</summary>
    internal Task BeginSignOut()
    {
        string? id, token;
        lock (_lock) (id, token) = ForgetForSignOut();
        return RemoveAtClerkAsync(id, token);
    }

    private (string? Session, string? Token) ForgetForSignOut()
    {
        AssertLocked();
        var result = (_state.SessionId, _state.ClientToken);
        _generation++;
        _state = new ClerkState { FrontendApi = ClerkPublishableKey.Origin(FrontendApi) };
        _cachedToken = null;
        _lastClient = null;
        Save();
        return result;
    }

    private async Task RemoveAtClerkAsync(string? session, string? token)
    {
        if (session is null) return;
        try { await RequestAsync("POST", $"/v1/client/sessions/{session}/remove", tokenOverride: true, overrideToken: token).ConfigureAwait(false); }
        catch (Exception) { }
    }

    // MARK: Email code

    /// <summary>Sends a 6-digit code to <paramref name="email"/>. A known address signs in; a new one signs up, with the same next step.</summary>
    public async Task<ClerkEmailChallenge> StartEmailAsync(string email, CancellationToken cancellationToken = default)
    {
        var address = email.Trim();
        var generation = CurrentGeneration();
        try
        {
            var signIn = Response(await RequestAsync("POST", "/v1/client/sign_ins", new() { ["identifier"] = address }, generation: generation, cancellationToken: cancellationToken).ConfigureAwait(false));
            var id = signIn["id"]?.GetValue<string>() ?? throw ClerkException.Unexpected("no sign-in id");
            var factor = (signIn["supported_first_factors"] as JsonArray)?.OfType<JsonObject>()
                .FirstOrDefault(f => f["strategy"]?.GetValue<string>() == "email_code");
            var emailId = factor?["email_address_id"]?.GetValue<string>() ?? throw ClerkException.UnsupportedRequirements(["a password"]);
            await RequestAsync("POST", $"/v1/client/sign_ins/{id}/prepare_first_factor",
                new() { ["strategy"] = "email_code", ["email_address_id"] = emailId }, generation: generation, cancellationToken: cancellationToken).ConfigureAwait(false);
            return new ClerkEmailChallenge(ClerkChallengeKind.SignIn, id, address);
        }
        catch (ClerkException e) when (e.Kind == ClerkErrorKind.Refused && e.Code == "form_identifier_not_found")
        {
            var signUp = Response(await RequestAsync("POST", "/v1/client/sign_ups", new() { ["email_address"] = address }, generation: generation, cancellationToken: cancellationToken).ConfigureAwait(false));
            var id = signUp["id"]?.GetValue<string>() ?? throw ClerkException.Unexpected("no sign-up id");
            await RequestAsync("POST", $"/v1/client/sign_ups/{id}/prepare_verification", new() { ["strategy"] = "email_code" }, generation: generation, cancellationToken: cancellationToken).ConfigureAwait(false);
            return new ClerkEmailChallenge(ClerkChallengeKind.SignUp, id, address);
        }
    }

    /// <summary>Completes an email sign-in or sign-up with the code from the email.</summary>
    /// <remarks>
    /// Bound to the generation it starts in: a sign-out, an ended session or another sign-in that finishes first makes it
    /// <see cref="ClerkErrorKind.Stale"/>, and it then adopts nothing.
    /// </remarks>
    public async Task<ClerkSession> VerifyEmailAsync(ClerkEmailChallenge challenge, string code, CancellationToken cancellationToken = default)
    {
        var flow = StartFlow();
        var generation = flow.Generation;
        var digits = new string(code.Where(char.IsAsciiDigit).ToArray());
        var path = challenge.Kind == ClerkChallengeKind.SignIn
            ? $"/v1/client/sign_ins/{challenge.AttemptId}/attempt_first_factor"
            : $"/v1/client/sign_ups/{challenge.AttemptId}/attempt_verification";
        var attempt = Response(await RequestAsync("POST", path, new() { ["strategy"] = "email_code", ["code"] = digits }, generation: generation, cancellationToken: cancellationToken, flow: flow).ConfigureAwait(false));
        if (challenge.Kind == ClerkChallengeKind.SignUp && MissesOnlyPassword(attempt))
        {
            // A Clerk app that requires a password at sign-up (Clerk's default; only the dashboard turns it off): give the
            // new account a long random one, never shown, saved or sent anywhere else. OpenMusic signs in with email codes.
            attempt = Response(await RequestAsync("PATCH", $"/v1/client/sign_ups/{challenge.AttemptId}",
                new() { ["password"] = UnusedPassword() }, generation: generation, cancellationToken: cancellationToken, flow: flow).ConfigureAwait(false));
        }
        return await FinishAsync(attempt, flow, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>A sign-up whose email is verified and whose only missing field is the password.</summary>
    internal static bool MissesOnlyPassword(JsonObject signUp) =>
        signUp["status"]?.GetValue<string>() == "missing_requirements"
        && signUp["missing_fields"] is JsonArray missing && missing.Count == 1 && missing[0]?.GetValue<string>() == "password"
        && (signUp["unverified_fields"] is not JsonArray unverified || unverified.Count == 0);

    /// <summary>32 random bytes as base64url (43 characters): past any length rule, never in a breach list.</summary>
    internal static string UnusedPassword() => Base64Url.Encode(System.Security.Cryptography.RandomNumberGenerator.GetBytes(32));

    // MARK: Social sign-in

    /// <summary>Starts a social sign-in; open the returned URL in the system browser.</summary>
    public async Task<ClerkOAuthStart> StartOAuthAsync(ClerkOAuthProvider provider, CancellationToken cancellationToken = default)
    {
        var form = new Dictionary<string, string> { ["strategy"] = provider.Strategy, ["redirect_url"] = OAuthRedirect };
        var generation = CurrentGeneration();
        var signIn = Response(await RequestAsync("POST", "/v1/client/sign_ins", form, generation: generation, cancellationToken: cancellationToken).ConfigureAwait(false));
        var id = signIn["id"]?.GetValue<string>() ?? throw ClerkException.Unexpected("no sign-in id");
        if (ExternalUrl(signIn) is null)
            signIn = Response(await RequestAsync("POST", $"/v1/client/sign_ins/{id}/prepare_first_factor", form, generation: generation, cancellationToken: cancellationToken).ConfigureAwait(false));
        var url = ExternalUrl(signIn) ?? throw ClerkException.Unexpected("Clerk returned no sign-in page");
        return new ClerkOAuthStart(url, id);
    }

    /// <summary>Finishes a social sign-in from the callback URL. A first-time user is signed up from the same sign-in ("transfer").</summary>
    public async Task<ClerkSession> CompleteOAuthAsync(ClerkOAuthStart start, Uri callback, CancellationToken cancellationToken = default)
    {
        if (callback.Scheme != ProductInfo.UrlScheme || callback.Host != "oauth-callback") throw ClerkException.Unexpected("unexpected callback");
        var query = new Dictionary<string, string>();
        var nonce = System.Web.HttpUtility.ParseQueryString(callback.Query)["rotating_token_nonce"];
        if (!string.IsNullOrEmpty(nonce)) query["rotating_token_nonce"] = nonce;
        var flow = StartFlow();
        var generation = flow.Generation;
        var signIn = Response(await RequestAsync("GET", $"/v1/client/sign_ins/{start.SignInId}", query: query, generation: generation, cancellationToken: cancellationToken, flow: flow).ConfigureAwait(false));
        var verification = signIn["first_factor_verification"] as JsonObject;
        if (verification?["status"]?.GetValue<string>() == "transferable")
        {
            var signUp = Response(await RequestAsync("POST", "/v1/client/sign_ups", new() { ["transfer"] = "true" }, generation: generation, cancellationToken: cancellationToken, flow: flow).ConfigureAwait(false));
            return await FinishAsync(signUp, flow, cancellationToken).ConfigureAwait(false);
        }
        if (verification?["error"] is JsonObject error)
            throw ClerkException.Refused(error["code"]?.GetValue<string>() ?? "oauth", Message(error) ?? "Sign-in was cancelled.");
        // Still waiting for the browser (no answer from Google or Apple yet): this callback isn't this sign-in's.
        if (signIn["status"]?.GetValue<string>() is "needs_identifier" or "needs_first_factor" && verification?["status"]?.GetValue<string>() is null or "unverified")
            throw ClerkException.NotFinished();
        return await FinishAsync(signIn, flow, cancellationToken).ConfigureAwait(false);
    }

    // MARK: Tokens

    /// <summary>The Convex JWT (template <c>convex</c>), cached until 10 s before it expires. Null when signed out or ended.</summary>
    public Task<string?> GetTokenAsync(bool forceRefresh, CancellationToken cancellationToken = default) => TokenAsync(forceRefresh, true, cancellationToken);

    private async Task<string?> TokenAsync(bool forceRefresh, bool retryIfStale, CancellationToken cancellationToken)
    {
        string session;
        int generation;
        lock (_lock)
        {
            if (_state.SessionId is not { } s) return null;
            session = s;
            if (!forceRefresh && _cachedToken is { } cached && !cached.NeedsRefresh()) return cached.Value;
            // The session and its generation are read together: the request is sent and judged in this generation, so an
            // answer about this session (a token, or "session gone") never lands on a session that replaced it.
            generation = _generation;
        }
        if (WillRequestToken is { } hook) await hook().ConfigureAwait(false);
        try
        {
            var obj = await RequestAsync("POST", $"/v1/client/sessions/{session}/tokens/{TokenTemplate}", generation: generation, cancellationToken: cancellationToken).ConfigureAwait(false);
            var jwt = obj["jwt"]?.GetValue<string>() ?? throw ClerkException.Unexpected("no token");
            lock (_lock)
            {
                if (generation != _generation) throw ClerkException.Stale();
                _cachedToken = new AuthToken(jwt);
            }
            return jwt;
        }
        catch (ClerkException e) when (e.Kind == ClerkErrorKind.Refused && SessionGoneCodes.Contains(e.Code ?? ""))
        {
            lock (_lock) { if (generation == _generation) EndSession(null); }
            return null;
        }
        catch (ClerkException e) when (e.Kind == ClerkErrorKind.Stale)
        {
            bool signedIn;
            lock (_lock) signedIn = _state.SessionId is not null;
            if (!retryIfStale || !signedIn) return null;
            return await TokenAsync(true, false, cancellationToken).ConfigureAwait(false);
        }
    }

    /// <summary>Tests only: runs after a token request picked its session, before it is sent.</summary>
    internal Func<Task>? WillRequestToken { get; set; }

    /// <summary>Answers that mean the session is gone for good (a server error is retried instead).</summary>
    internal static readonly HashSet<string> SessionGoneCodes = ["signed_out", "authentication_invalid", "resource_not_found", "session_not_found", "http_401", "http_404"];

    // MARK: Requests

    /// <summary>
    /// Adopts the session a completed attempt created, only if nothing moved the client on since the flow started
    /// (<paramref name="generation"/>): checked under the lock the session is adopted in.
    /// </summary>
    private async Task<ClerkSession> FinishAsync(JsonObject attempt, Flow flow, CancellationToken cancellationToken)
    {
        var generation = flow.Generation;
        var status = attempt["status"]?.GetValue<string>();
        if (status != "complete" || attempt["created_session_id"]?.GetValue<string>() is not { } sessionId)
        {
            var missing = ((attempt["missing_fields"] as JsonArray) ?? []).Concat((attempt["unverified_fields"] as JsonArray) ?? [])
                .Select(n => n?.GetValue<string>().Replace('_', ' ')).OfType<string>().ToList();
            if (missing.Count > 0) throw ClerkException.UnsupportedRequirements(missing);
            if (status == "needs_second_factor") throw ClerkException.UnsupportedRequirements(["a second factor"]);
            throw ClerkException.Unexpected($"sign-in isn't complete ({status ?? "no status"})");
        }
        // Make it the client's active session, as clerk-js setActive does.
        JsonObject touched;
        try
        {
            touched = await RequestAsync("POST", $"/v1/client/sessions/{sessionId}/touch", generation: generation, cancellationToken: cancellationToken, flow: flow).ConfigureAwait(false);
            if (WillAdoptFinishedSession is { } hook) await hook().ConfigureAwait(false);
        }
        catch (Exception)
        {
            // Any failure before adoption (stale, network, cancellation, refusal): the session Clerk created for this flow
            // is never adopted, so end it there with the flow's token instead of leaving it active.
            _ = RemoveAtClerkAsync(sessionId, flow.Token);
            throw;
        }
        lock (_lock)
        {
            // A sign-out, an ended session or a sign-in that finished first since this flow started: adopt nothing, and
            // end the session Clerk made for it, so it isn't left signed in there.
            if (generation != _generation)
            {
                _ = RemoveAtClerkAsync(sessionId, flow.Token);
                throw ClerkException.Stale();
            }
            var client = touched["client"] as JsonObject ?? _lastClient;
            var session = client is null ? null : ActiveSession(client, sessionId) ?? throw ClerkException.Unexpected("the new session is missing");
            if (session is null) throw ClerkException.Unexpected("the new session is missing");
            // A new session: anything still running for the previous one is dropped when it returns. The session it replaces
            // is ended at Clerk too: one account per device, and no sign-in is left active there unshown.
            if (_state.SessionId is { } replaced && replaced != session.Id) _ = RemoveAtClerkAsync(replaced, _state.ClientToken);
            _generation++;
            _state = _state with { SessionId = session.Id, User = session.User };
            _cachedToken = null;
            Save();
            return session;
        }
    }

    /// <summary>Tests only: runs after a sign-in's touch answered, before the session is adopted.</summary>
    internal Func<Task>? WillAdoptFinishedSession { get; set; }

    /// <summary>Forgets the session Clerk ended and tells the app which one it was. Call under the lock.</summary>
    private void EndSession(ClerkUser? notAdopted)
    {
        AssertLocked();
        var ended = _state.SessionId is { } id ? new ClerkSessionEnd(id, _state.User?.Id, notAdopted) : null;
        _generation++;
        _state = _state with { SessionId = null, User = null };
        _cachedToken = null;
        Save();
        if (ended is not null && _onSessionEnded is { } handler) ThreadPool.QueueUserWorkItem(_ => handler(ended));
    }

    private void Save()
    {
        AssertLocked();
        if (_retired) return;
        _store.Save(_state);
    }

    private static JsonObject Response(JsonObject obj) => obj["response"] as JsonObject ?? throw ClerkException.Unexpected("empty response");

    /// <summary>
    /// Sends one request to this client's Frontend API. Throws Stale when the session generation changed while it was in
    /// flight: nothing from its response is kept. With <paramref name="tokenOverride"/>, sends <paramref name="overrideToken"/>
    /// and keeps nothing from the answer (the sign-out of a session already forgotten here).
    /// </summary>
    private async Task<JsonObject> RequestAsync(string method, string path, Dictionary<string, string>? form = null, Dictionary<string, string>? query = null,
                                                bool tokenOverride = false, string? overrideToken = null, int? generation = null, CancellationToken cancellationToken = default,
                                                Flow? flow = null)
    {
        var items = new List<string> { "_is_native=true" };
        if (query is not null) items.AddRange(query.OrderBy(kv => kv.Key, StringComparer.Ordinal).Select(kv => $"{FormEscape(kv.Key)}={FormEscape(kv.Value)}"));
        var url = new Uri($"https://{FrontendApi.Host}{path}?{string.Join("&", items)}");
        var headers = new Dictionary<string, string>
        {
            ["Content-Type"] = "application/x-www-form-urlencoded",
            ["clerk-api-version"] = ApiVersion,
            ["x-mobile"] = "0",
        };
        int started;
        string? sentToken;
        lock (_lock)
        {
            // A caller that decided on an earlier generation (it read the session then) is stale before anything is sent.
            if (generation is { } g && g != _generation) throw ClerkException.Stale();
            // A client retired by a server switch speaks for nobody: only the removal of a session it made still goes out
            // (explicit token), so a sign-in through a retained reference can't leave a session at the old server's Clerk.
            if (_retired && !tokenOverride) throw ClerkException.Stale();
            var token = tokenOverride ? overrideToken : _state.ClientToken;
            if (token is not null) headers["Authorization"] = token;
            sentToken = token;
            if (flow is not null && token is not null) flow.Token = token;
            started = generation ?? _generation;
        }
        var body = form is null ? null : Encoding.UTF8.GetBytes(FormEncode(form));
        ClerkResponse response;
        try { response = await _http.SendAsync(new ClerkRequest(method, url, headers, body), cancellationToken).ConfigureAwait(false); }
        catch (ClerkException) { throw; }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (Exception e) { throw ClerkException.Network(e.Message); }
        if (tokenOverride) return new JsonObject();
        JsonObject obj = new();
        bool stale;
        lock (_lock)
        {
            // The flow keeps the newest token of its client, stale or not: it may need it to undo what it did at Clerk.
            if (flow is not null && !string.IsNullOrEmpty(response.Authorization)) flow.Token = response.Authorization;
            // Signed out (or the session changed) while this was in flight: keep nothing from it. Decided once, here.
            stale = started != _generation;
            if (!stale) Keep();
        }
        if (stale)
        {
            // A sign-in step's answer that made a session at Clerk: ended there with the flow's token, so it isn't left active.
            if (flow is not null && response.Status is >= 200 and < 300)
            {
                try
                {
                    if ((JsonNode.Parse(response.Body) as JsonObject)?["response"]?["created_session_id"]?.GetValue<string>() is { } created)
                        _ = RemoveAtClerkAsync(created, flow.Token);
                }
                catch (Exception) { }
            }
            throw ClerkException.Stale();
        }
        if (response.Status is < 200 or >= 300)
        {
            var first = (obj["errors"] as JsonArray)?.FirstOrDefault() as JsonObject;
            var code = first?["code"]?.GetValue<string>() ?? $"http_{response.Status}";
            throw ClerkException.Refused(code, (first is null ? null : Message(first)) ?? $"Sign-in failed ({response.Status}).");
        }
        return obj;

        void Keep()
        {
            if (!string.IsNullOrEmpty(response.Authorization) && response.Authorization != _state.ClientToken)
            {
                _state = _state with { ClientToken = response.Authorization };
                Save();
            }
            try { obj = JsonNode.Parse(response.Body) as JsonObject ?? new JsonObject(); }
            catch (JsonException) { obj = new JsonObject(); }
            _lastClient = obj["client"] as JsonObject;
        }
    }

    internal static string FormEncode(Dictionary<string, string> form) =>
        string.Join("&", form.OrderBy(kv => kv.Key, StringComparer.Ordinal).Select(kv => $"{kv.Key}={FormEscape(kv.Value)}"));

    /// <summary>Percent-encodes everything but ASCII letters, digits and <c>-._~</c> (Swift's allowed set).</summary>
    private static string FormEscape(string value)
    {
        var sb = new StringBuilder();
        foreach (var b in Encoding.UTF8.GetBytes(value))
        {
            var c = (char)b;
            if (char.IsAsciiLetterOrDigit(c) || c is '-' or '.' or '_' or '~') sb.Append(c);
            else sb.Append('%').Append(b.ToString("X2", System.Globalization.CultureInfo.InvariantCulture));
        }
        return sb.ToString();
    }

    private static string? Message(JsonObject error) => error["long_message"]?.GetValue<string>() ?? error["message"]?.GetValue<string>();

    private static Uri? ExternalUrl(JsonObject signIn) =>
        signIn["first_factor_verification"]?["external_verification_redirect_url"]?.GetValue<string>() is { } s && Uri.TryCreate(s, UriKind.Absolute, out var u) ? u : null;

    internal static ClerkSession? ActiveSession(JsonObject client, string id) => ActiveSessions(client).FirstOrDefault(s => s.Id == id);

    /// <summary>The client's active sessions with their users, the last active one first.</summary>
    internal static List<ClerkSession> ActiveSessions(JsonObject client)
    {
        var last = client["last_active_session_id"]?.GetValueKind() == JsonValueKind.String ? client["last_active_session_id"]!.GetValue<string>() : null;
        return ((client["sessions"] as JsonArray) ?? []).OfType<JsonObject>()
            .Where(s => s["status"]?.GetValue<string>() == "active")
            .Select(ParseSession).OfType<ClerkSession>()
            .OrderBy(s => s.Id == last ? 0 : 1).ToList();
    }

    private static ClerkSession? ParseSession(JsonObject o)
    {
        if (o["id"]?.GetValue<string>() is not { } id || o["user"] is not JsonObject user || user["id"]?.GetValue<string>() is not { } userId) return null;
        string? Str(JsonNode? n) => n?.GetValueKind() == JsonValueKind.String ? n.GetValue<string>() : null;
        var emails = ((user["email_addresses"] as JsonArray) ?? []).OfType<JsonObject>().ToList();
        var primaryId = Str(user["primary_email_address_id"]);
        var primary = emails.FirstOrDefault(e => Str(e["id"]) == primaryId) ?? emails.FirstOrDefault();
        return new ClerkSession(id, new ClerkUser(userId, Str(user["first_name"]), Str(user["last_name"]), Str(primary?["email_address"]), Str(user["image_url"])));
    }
}
