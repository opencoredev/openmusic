namespace Medley.Providers.YouTube.Auth;

/// <summary>One cookie as a web view reports it (WebView2: <c>CoreWebView2Cookie.Name/Value/Domain</c>).</summary>
public sealed record WebCookie(string Name, string Value, string Domain);

/// <summary>
/// What a sign-in window (WebView2 on Windows) needs to sign in to YouTube Music the way the Swift app's web view does
/// (Swift: <c>YTMSignInWebView</c> and its navigator). The window itself is the app's.
/// </summary>
/// <remarks>
/// Flow: navigate to <see cref="StartUrl"/> in a web view with its own persistent profile (so re-sign-in is one click);
/// after every completed navigation, when <see cref="IsLanding"/> is true for the page's URL, read the cookies with
/// <c>CookieManager.GetCookiesAsync("https://music.youtube.com")</c>, pass them to
/// <see cref="CredentialsFromCookies"/>, then to <c>YouTubeMusicProvider.PrepareAccountsAsync(…, preferSelected: true)</c>.
/// An authoritative list with one account is committed at once (<c>CommitSignInAsync</c>); otherwise show the list.
/// Deliver once per load, and ignore deliveries after the window closed or the session was reset ("Use a different
/// account" clears the profile's cookies and reloads <see cref="StartUrl"/>).
/// </remarks>
public static class WebSignIn
{
    /// <summary>
    /// Google's account chooser, continuing to youtube.com's sign-in and then music.youtube.com. No <c>passive</c>:
    /// the person picks which account (and, for a brand account, which channel).
    /// </summary>
    public static Uri StartUrl { get; } = BuildStartUrl();

    static Uri BuildStartUrl()
    {
        // Encoded the way the Swift app's URLComponents does, so both apps open the same URL.
        static string E(string s) => InnerTube.InnerTubeClient.QueryEscape(s);
        var signin = "https://www.youtube.com/signin?action_handle_signin=true&app=desktop&hl=en&next=" + E("https://music.youtube.com/");
        var login = "https://accounts.google.com/AccountChooser?service=youtube&continue=" + E(signin) + "&hl=en";
        return new Uri(login);
    }

    /// <summary>The page the flow ends on. Cookies are read only there, never mid-flow on accounts.google.com.</summary>
    public const string LandingHost = "music.youtube.com";

    /// <summary>The URL whose cookies to read (it returns the <c>.youtube.com</c> session cookies too).</summary>
    public static Uri CookieUrl { get; } = new("https://music.youtube.com/");

    /// <summary>Cookies are kept when their domain ends with this (as in the Swift app).</summary>
    public const string CookieDomainSuffix = "youtube.com";

    /// <summary>
    /// The cookies a usable sign-in must have: <c>SAPISID</c> (or <c>__Secure-3PAPISID</c>) and one of
    /// <c>SID</c>, <c>__Secure-3PSID</c>, <c>__Secure-1PSID</c>. Every other youtube.com cookie is kept too: Google
    /// checks several of them (<c>HSID</c>, <c>SSID</c>, <c>APISID</c>, <c>__Secure-1PAPISID</c>, <c>LOGIN_INFO</c>,
    /// <c>*PSIDTS</c>, <c>*PSIDCC</c>…).
    /// </summary>
    public static IReadOnlyList<string> RequiredCookies { get; } = ["SAPISID|__Secure-3PAPISID", "SID|__Secure-3PSID|__Secure-1PSID"];

    /// <summary>
    /// The Safari user agent the Swift app's WebKit view uses. Don't set it on WebView2: Chromium's client hints would then
    /// disagree with it. WebView2's own user agent is accepted by Google's sign-in.
    /// </summary>
    public const string AppleWebKitUserAgent = InnerTube.InnerTubeProfile.SafariUserAgent;

    public static bool IsLanding(Uri? url) => url != null && string.Equals(url.Host, LandingHost, StringComparison.OrdinalIgnoreCase);

    /// <summary>The session cookies for youtube.com, or null when the jar can't authenticate yet (still signing in).</summary>
    public static YouTubeMusicCredentials? CredentialsFromCookies(IEnumerable<WebCookie> cookies)
    {
        var jar = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var c in cookies)
        {
            if (c.Domain.EndsWith(CookieDomainSuffix, StringComparison.OrdinalIgnoreCase)) jar[c.Name] = c.Value;
        }
        var creds = new YouTubeMusicCredentials(jar);
        return creds.IsUsable ? creds : null;
    }
}
