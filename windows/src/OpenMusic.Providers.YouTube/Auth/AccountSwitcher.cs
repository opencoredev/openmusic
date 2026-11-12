using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using OpenMusic.Core;
using OpenMusic.Providers.YouTube.Json;
using OpenMusic.Providers.YouTube.Parsing;

namespace OpenMusic.Providers.YouTube.Auth;

/// <summary>
/// One identity in YouTube's account switcher: a Google account (<see cref="AuthUser"/>) or a channel / brand account
/// under it (selected by <see cref="DatasyncId"/>). What the browser shows under the avatar.
/// </summary>
public sealed record AccountIdentity(
    int AuthUser,
    string? DatasyncId = null,
    string? ListedName = null,
    string? ListedByline = null,
    Uri? Photo = null,
    bool IsSelected = false)
{
    /// <summary>The delegated session id that selects a brand channel. Null for a personal account.</summary>
    public string? DelegatedSessionId => YouTubeMusicCredentials.DelegatedSessionIdOf(DatasyncId);

    /// <summary>A stable key for this identity's selectors, to dedupe without relying on the display name.</summary>
    public string SelectorKey => $"{AuthUser}|{DelegatedSessionId ?? ""}";
}

/// <summary>The accounts a sign-in can use, and whether the list came from the account switcher (authoritative).</summary>
public sealed record AccountChoiceList(IReadOnlyList<AccountChoice> Accounts, bool Authoritative);

/// <summary>One account OpenMusic can sign in as: confirmed <see cref="Info"/> and how requests select it.</summary>
public sealed record AccountChoice(AccountIdentity Identity, AccountInfo Info)
{
    public string Id => Identity.SelectorKey;

    /// <summary>The prepared login this choice came from: committing it uses that login's credentials, never another's.</summary>
    internal PreparedLogin? Login { get; init; }
}

/// <summary>The credentials one prepare confirmed, held until a choice from it commits. Compared by reference.</summary>
internal sealed class PreparedLogin(YouTubeMusicCredentials credentials, string sourceName)
{
    public YouTubeMusicCredentials Credentials { get; } = credentials;
    public string SourceName { get; } = sourceName;
}

/// <summary>
/// Parses <c>getAccountSwitcherEndpoint</c> into the identities it lists, in document order (Swift:
/// <c>AccountSwitcherParser</c>). Each item's selectors sit in
/// <c>serviceEndpoint.selectActiveIdentityEndpoint.supportedTokens</c>; the authUser comes from the sign-in URL when
/// present, else the section's order. Each identity is still confirmed by a real request before it is offered.
/// </summary>
public static class AccountSwitcherParser
{
    public static IReadOnlyList<AccountIdentity> Identities(string json)
    {
        JsonNode? root;
        try { root = JsonNav.Parse(json); }
        catch (JsonException) { return []; }
        if (root == null) return [];
        var sections = Collect("accountItemSectionRenderer", root);
        var identities = new List<AccountIdentity>();
        if (sections.Count == 0)
        {
            foreach (var item in Collect("accountItem", root))
            {
                if (Identity(item, 0) is { } id) identities.Add(id);
            }
        }
        else
        {
            for (var authUser = 0; authUser < sections.Count; authUser++)
            {
                foreach (var item in Collect("accountItem", sections[authUser]))
                {
                    if (Identity(item, authUser) is { } id) identities.Add(id);
                }
            }
        }
        return identities;
    }

    static AccountIdentity? Identity(JsonNode? item, int authUser)
    {
        if (item is not JsonObject dict) return null;
        var name = Text(dict.Get("accountName")) ?? Text(dict.Get("channelTitle"));
        var byline = Text(dict.Get("accountByline")) ?? Text(dict.Get("channelHandle")) ?? Text(dict.Get("email"));
        var photo = FirstString("url", dict.Get("accountPhoto")) is { } p && Uri.TryCreate(p, UriKind.Absolute, out var u) ? u : null;
        // `datasyncIdToken.datasyncIdToken` is the real shape; `datasyncId` is accepted too in case it changes back.
        var datasyncId = FirstString("datasyncIdToken", dict) ?? FirstString("datasyncId", dict);
        var signinUrl = FirstString("signinUrl", dict);
        // An item with no selector and no name is a header or separator, not an account.
        if (name == null && datasyncId == null) return null;
        var resolved = signinUrl != null && PageParser.QueryValue(signinUrl, "authuser") is { Length: > 0 } au &&
                       int.TryParse(au, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var n) ? n : authUser;
        return new AccountIdentity(resolved, datasyncId, name, byline, photo, dict.B("isSelected") ?? false);
    }

    static string? Text(JsonNode? value)
    {
        if (value is not JsonObject dict) return null;
        if (JsonNav.AsString(dict.Get("simpleText")) is { } simple) return simple.Length == 0 ? null : simple;
        if (dict.Get("runs") is JsonArray runs)
        {
            var joined = string.Concat(runs.Select(r => r.S("text")).Where(t => t != null));
            return joined.Length == 0 ? null : joined;
        }
        return null;
    }

    /// <summary>Every value stored under <paramref name="key"/>, depth first, descending into matches too.</summary>
    static List<JsonNode?> Collect(string key, JsonNode? value)
    {
        var output = new List<JsonNode?>();
        void Walk(JsonNode? v)
        {
            switch (v)
            {
                case JsonObject o:
                    foreach (var (k, sub) in o)
                    {
                        if (k == key) output.Add(sub);
                        Walk(sub);
                    }
                    break;
                case JsonArray a:
                    foreach (var sub in a) Walk(sub);
                    break;
            }
        }
        Walk(value);
        return output;
    }

    /// <summary>The first non-empty string stored under <paramref name="key"/> anywhere in <paramref name="value"/>.</summary>
    static string? FirstString(string key, JsonNode? value)
    {
        string? found = null;
        void Walk(JsonNode? v)
        {
            if (found != null) return;
            switch (v)
            {
                case JsonObject o:
                    foreach (var (k, sub) in o)
                    {
                        if (found != null) return;
                        if (k == key && JsonNav.AsString(sub) is { Length: > 0 } s) { found = s; return; }
                        Walk(sub);
                    }
                    break;
                case JsonArray a:
                    foreach (var sub in a) Walk(sub);
                    break;
            }
        }
        Walk(value);
        return found;
    }
}
