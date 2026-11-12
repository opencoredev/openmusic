using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Serialization;

namespace OpenMusic.Core.Support;

/// <summary>What one cached browse page holds on disk.</summary>
public sealed record BrowseCacheFile(
    [property: JsonPropertyName("version")] int Version,
    [property: JsonPropertyName("savedAt")] DateTimeOffset SavedAt,
    [property: JsonPropertyName("shelves")] List<Shelf> Shelves);

/// <summary>
/// Home and New on disk, so the next launch draws them at once and refreshes behind them (Swift:
/// <c>BrowseDiskCache</c>). A file is keyed by its page and by a hash of the account the request was sent as
/// (<see cref="ProviderSession"/>), never by a name or email, so one account's shelves are never shown to another.
/// <list type="bullet">
/// <item>Only settled sessions are cached: signed out, or signed in with an account id. A session that is changing or
/// signed in without an id (cookies pasted by hand) reads and writes nothing.</item>
/// <item><see cref="Retain"/> deletes every file but the current account's and the signed-out ones, so signing out or
/// switching leaves nothing of the old account behind.</item>
/// <item>Writes go to a temp file and replace the old one. A file that doesn't parse, is from another version or is
/// older than <see cref="MaxAge"/> counts as missing and is deleted.</item>
/// </list>
/// Thread-safe; file work is synchronous and small (a few hundred kB), so call it off the UI thread.
/// </summary>
public sealed class BrowseDiskCache
{
    public const int Version = 1;
    public static readonly TimeSpan MaxAge = TimeSpan.FromDays(14);

    private readonly string _directory;
    private readonly TimeProvider _time;
    private readonly Lock _lock = new();

    public BrowseDiskCache(string directory, TimeProvider? time = null)
    {
        _directory = directory;
        _time = time ?? TimeProvider.System;
    }

    /// <summary>The file's account part: "anon" signed out, a hash of provider and account id when signed in, null
    /// when the session must not be cached.</summary>
    public static string? AccountKey(ProviderId provider, ProviderSession session) => session.Identity.Kind switch
    {
        SessionIdentityKind.SignedOut => "anon",
        SessionIdentityKind.Account when session.Identity.AccountId is { Length: > 0 } id => Hash($"{provider.RawValue()}:{id}"),
        _ => null,
    };

    private static string Hash(string text) =>
        Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text)))[..20];

    private string? PathFor(string page, ProviderId provider, ProviderSession session)
    {
        if (AccountKey(provider, session) is not { } account) return null;
        foreach (var c in page)
            if (!char.IsAsciiLetterOrDigit(c)) throw new ArgumentException($"page names are letters and digits: {page}");
        return Path.Combine(_directory, $"{provider.RawValue()}-{page}-{account}.json");
    }

    /// <summary>The saved shelves for this page and session, or null.</summary>
    public IReadOnlyList<Shelf>? Load(string page, ProviderId provider, ProviderSession session)
    {
        if (PathFor(page, provider, session) is not { } path) return null;
        lock (_lock)
        {
            try
            {
                if (!File.Exists(path)) return null;
                var file = OpenMusicJson.Deserialize(File.ReadAllBytes(path), OpenMusicJsonContext.Default.BrowseCacheFile);
                if (file is null || file.Version != Version || _time.GetUtcNow() - file.SavedAt > MaxAge || file.Shelves.Count == 0)
                {
                    TryDelete(path);
                    return null;
                }
                return file.Shelves;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Text.Json.JsonException or NotSupportedException)
            {
                TryDelete(path);
                return null;
            }
        }
    }

    /// <summary>Saves the shelves a request sent as <paramref name="session"/> returned. Returns whether it was written.</summary>
    public bool Save(string page, ProviderId provider, ProviderSession session, IReadOnlyList<Shelf> shelves)
    {
        if (shelves.Count == 0 || PathFor(page, provider, session) is not { } path) return false;
        var bytes = OpenMusicJson.SerializeToUtf8(new BrowseCacheFile(Version, _time.GetUtcNow(), [.. shelves]), OpenMusicJsonContext.Default.BrowseCacheFile);
        lock (_lock)
        {
            try
            {
                Directory.CreateDirectory(_directory);
                var temp = path + ".tmp";
                File.WriteAllBytes(temp, bytes);
                File.Move(temp, path, overwrite: true);
                return true;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                return false;
            }
        }
    }

    /// <summary>Deletes every file of <paramref name="provider"/> except the signed-out ones and those of
    /// <paramref name="current"/> (when it is a cacheable account). Call when the provider's session settles.</summary>
    public void Retain(ProviderId provider, ProviderSession current)
    {
        var keep = AccountKey(provider, current);
        lock (_lock)
        {
            if (!Directory.Exists(_directory)) return;
            foreach (var path in Directory.EnumerateFiles(_directory, $"{provider.RawValue()}-*"))
            {
                var name = Path.GetFileNameWithoutExtension(path);
                if (name.EndsWith(".json", StringComparison.Ordinal)) name = name[..^5]; // a leftover .json.tmp
                var account = name[(name.LastIndexOf('-') + 1)..];
                if (account == "anon" || account == keep) continue;
                TryDelete(path);
            }
        }
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}
