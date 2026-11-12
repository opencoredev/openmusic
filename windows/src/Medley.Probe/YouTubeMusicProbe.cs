using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using Medley.Core;
using Medley.Providers.YouTube;
using Medley.Providers.YouTube.Auth;
using Medley.Providers.YouTube.InnerTube;
using Medley.Providers.YouTube.Playback;
using Medley.Providers.YouTube.Sync;

namespace Medley.Probe;

/// <summary>
/// Probe commands for YouTube Music (Swift: Sources/MedleyProbe/YouTubeMusicProbe.swift).
///
///   medley-probe ytm search &lt;query&gt; [all|songs|albums|artists|playlists]
///   medley-probe ytm suggest &lt;query&gt;
///   medley-probe ytm link &lt;videoId&gt;          (album and artist links for a song)
///   medley-probe ytm home | explore | more &lt;moreToken&gt;
///   medley-probe ytm album &lt;MPREb id&gt; | artist &lt;UC id&gt; | playlist &lt;id&gt; [--all]
///   medley-probe ytm radio &lt;videoId&gt; | radio-seed &lt;artist/playlist id&gt;
///   medley-probe ytm lyrics &lt;videoId&gt; [--title T --artist A]   (with title and artist, LRCLIB can fill in)
///   medley-probe ytm stream &lt;videoId&gt; [--hls]   (resolves the stream and prints its details; never saves audio)
///   medley-probe ytm raw &lt;endpoint&gt; &lt;json&gt; [--client ANDROID_MUSIC|VISIONOS|ANDROID_VR|IOS] [--out file]
///   medley-probe ytm whoami | library &lt;likedSongs|songs|albums|artists|playlists|recentlyPlayed&gt; | accounts   (need --cookies)
///   medley-probe ytm signin-url
///   medley-probe ytm transfer-export   (prints the sign-in payload's shape, never its cookies; needs --cookies)
///
/// --cookies &lt;file&gt;: a Cookie header, a credentials JSON, a sign-in transfer payload, or a Netscape cookies.txt.
/// </summary>
internal static class YouTubeMusicProbe
{
    public static async Task<int> RunAsync(string[] argv)
    {
        var args = argv.ToList();
        string? Option(string name)
        {
            var i = args.IndexOf(name);
            if (i < 0 || i + 1 >= args.Count) return null;
            var value = args[i + 1];
            args.RemoveRange(i, 2);
            return value;
        }
        bool Flag(string name) => args.Remove(name);

        var cookiesFile = Option("--cookies");
        var clientName = Option("--client");
        var outPath = Option("--out");
        var title = Option("--title");
        var artistName = Option("--artist");
        var all = Flag("--all");
        var hls = Flag("--hls");
        if (args.Count == 0) return Usage();
        var command = args[0];
        var rest = args.Skip(1).ToList();

        using var provider = new YouTubeMusicProvider(new YouTubeMusicProviderOptions { StreamPreference = hls ? StreamPreference.Hls : StreamPreference.Direct });
        if (cookiesFile != null)
        {
            var creds = LoadCookies(cookiesFile) ?? throw new InvalidOperationException($"{cookiesFile}: no usable YouTube cookies (need SAPISID and SID)");
            await provider.SignInAsync(creds, persist: false);
            if (provider.AuthStatus.Account is { } signedIn) Console.WriteLine($"signed in as {signedIn.Name} ({signedIn.Detail ?? "-"})");
        }

        switch (command)
        {
            case "search":
            {
                if (rest.Count == 0) return Usage();
                var scope = rest.Count > 1 && Enum.TryParse<SearchScope>(rest[1], true, out var sc) ? sc : SearchScope.All;
                var r = await provider.SearchAsync(rest[0], scope);
                if (r.Top != null) Console.WriteLine($"top: {Describe(r.Top)}");
                Section("songs", r.Tracks.Select(Describe));
                Section("albums", r.Albums.Select(Describe));
                Section("artists", r.Artists.Select(Describe));
                Section("playlists", r.Playlists.Select(Describe));
                break;
            }
            case "suggest":
            {
                if (rest.Count == 0) return Usage();
                var s = await provider.RichSearchSuggestionsAsync(rest[0]);
                foreach (var q in s.Queries) Console.WriteLine($"  {q}");
                Section("direct matches", s.Items.Select(Describe));
                break;
            }
            case "link":
            {
                if (rest.Count == 0) return Usage();
                var t = await provider.LinkedTrackAsync(new Track { Provider = ProviderId.YouTubeMusic, ProviderID = rest[0], Title = "?" });
                Console.WriteLine(Describe(t));
                Console.WriteLine($"  album id: {t.Album?.Id ?? "-"}  artist ids: {string.Join(", ", t.Artists.Select(a => a.Id ?? "-"))}");
                Console.WriteLine($"  artwork: {t.Artwork?.Url(120)?.Host ?? "-"} ({t.Artwork?.Images.Count ?? 0} sizes)");
                break;
            }
            case "home":
            case "explore":
            {
                var shelves = command == "home" ? await provider.HomeAsync() : await provider.ExploreAsync();
                Console.WriteLine($"{shelves.Count} shelves");
                foreach (var shelf in shelves) PrintShelf(shelf);
                break;
            }
            case "more":
                if (rest.Count == 0) return Usage();
                PrintShelf(await provider.ShelfAsync(rest[0]), 50);
                break;
            case "album":
            {
                if (rest.Count == 0) return Usage();
                var d = await provider.AlbumAsync(rest[0]);
                Console.WriteLine($"{d.Album.Title} — {d.Album.ArtistLine} [{d.Album.Kind}{(d.Album.Year is { } y ? $", {y}" : "")}]");
                Console.WriteLine($"  footnote: {d.Footnote ?? "-"}  playlistId: {d.Album.Extra.GetValueOrDefault("playlistId") ?? "-"}  art: {Art(d.Album.Artwork)}");
                if (d.Summary is { } about) Console.WriteLine($"  about: {Trunc(about, 100)}…");
                foreach (var t in d.Tracks) Console.WriteLine($"  {t.TrackNumber,2}. {Describe(t)}");
                Section("more by artist", (d.MoreByArtist ?? []).Select(Describe));
                break;
            }
            case "artist":
            {
                if (rest.Count == 0) return Usage();
                var d = await provider.ArtistAsync(rest[0]);
                Console.WriteLine($"{d.Artist.Name} — {d.Artist.Subtitle ?? ""}  radioSeed: {d.RadioSeed ?? "-"}  followed: {d.IsFollowed?.ToString() ?? "-"}  art: {Art(d.Artist.Artwork)}");
                if (d.Bio is { } bio) Console.WriteLine($"  bio: {Trunc(bio, 100)}…");
                Section("top songs", d.TopTracks.Select(Describe));
                Section("albums", d.Albums.Select(Describe));
                Section("singles", d.Singles.Select(Describe));
                Section("playlists", d.Playlists.Select(Describe));
                Section("related", d.Related.Select(Describe));
                break;
            }
            case "playlist":
            {
                if (rest.Count == 0) return Usage();
                var d = await provider.PlaylistAsync(rest[0]);
                Console.WriteLine($"{d.Playlist.Title} — {d.Playlist.Owner ?? "-"}  count: {d.Playlist.TrackCount?.ToString(CultureInfo.InvariantCulture) ?? "-"}  editable: {d.Playlist.IsEditable}  art: {Art(d.Playlist.Artwork)}");
                var tracks = d.Tracks.ToList();
                var token = d.Continuation;
                var pages = 1;
                if (all)
                {
                    while (token != null && pages < 100)
                    {
                        var page = await provider.PlaylistTracksAsync(token);
                        Console.WriteLine($"  continuation page {pages}: +{page.Items.Count} tracks");
                        tracks.AddRange(page.Items);
                        token = page.Continuation;
                        pages++;
                    }
                }
                var distinct = tracks.Select(t => t.ProviderID).Distinct().Count();
                Console.WriteLine($"  {tracks.Count} tracks ({distinct} distinct) loaded in {pages} page(s); more: {token != null}");
                for (var i = 0; i < tracks.Count; i++)
                {
                    if (i < 5 || i >= tracks.Count - 3) Console.WriteLine($"  {i + 1,3}. {Describe(tracks[i])}");
                }
                break;
            }
            case "radio":
            {
                if (rest.Count == 0) return Usage();
                var tracks = await provider.RadioAsync(new Track { Provider = ProviderId.YouTubeMusic, ProviderID = rest[0], Title = rest[0] });
                Console.WriteLine($"radio for {rest[0]}: {tracks.Count} tracks");
                foreach (var t in tracks.Take(12)) Console.WriteLine($"  {Describe(t)}");
                break;
            }
            case "radio-seed":
            {
                if (rest.Count == 0) return Usage();
                var tracks = await provider.RadioAsync(rest[0]);
                Console.WriteLine($"radio from {rest[0]}: {tracks.Count} tracks");
                foreach (var t in tracks.Take(12)) Console.WriteLine($"  {Describe(t)}");
                break;
            }
            case "lyrics":
            {
                if (rest.Count == 0) return Usage();
                var track = new Track
                {
                    ProviderID = rest[0], Provider = ProviderId.YouTubeMusic, Title = title ?? rest[0], Artists = artistName == null ? [] : [new ArtistRef(null, artistName)],
                };
                // The app always has the song's title, artist, album and length (LRCLIB needs them); look them up like a
                // queue row would carry them, unless given.
                if (title == null && await provider.Client.LinkedTrackAsync(rest[0]) is { } listed) track = listed;
                Console.WriteLine($"track: {Describe(track)}");
                if (await provider.LyricsAsync(track) is not { } lyrics) { Console.WriteLine("no lyrics"); return 0; }
                Console.WriteLine($"synced: {lyrics.IsSynced}  lines: {lyrics.Lines.Count}  source: {lyrics.Source ?? "-"}");
                foreach (var line in lyrics.Lines.Where(l => l.Text.Length > 0).Take(10))
                {
                    var time = line.Time is { } ts ? string.Create(CultureInfo.InvariantCulture, $"[{ts,6:000.00}]") : "        ";
                    Console.WriteLine($"  {time} {line.Text}");
                }
                break;
            }
            case "stream":
            {
                if (rest.Count == 0) return Usage();
                var r = await provider.StreamResolver.ResolveAsync(rest[0]);
                var s = r.Stream;
                Console.WriteLine($"client: {r.Client}  itag: {r.Itag?.ToString(CultureInfo.InvariantCulture) ?? "-"}  mime: {s.MimeType ?? "-"}  bitrate: {s.Bitrate?.ToString(CultureInfo.InvariantCulture) ?? "-"}");
                Console.WriteLine($"host: {s.Url.Host}  loudnessDb: {s.LoudnessDb?.ToString("0.00", CultureInfo.InvariantCulture) ?? "-"}  duration: {s.Duration?.ToString(CultureInfo.InvariantCulture) ?? "-"}s  expires: {s.ExpiresAt?.ToString("O", CultureInfo.InvariantCulture) ?? "-"}");
                break;
            }
            case "raw":
            {
                if (rest.Count < 2) return Usage();
                var profile = clientName switch
                {
                    null => null,
                    "ANDROID_MUSIC" => InnerTubeProfile.AndroidMusic,
                    "VISIONOS" => InnerTubeProfile.VisionOS,
                    "ANDROID_VR" => InnerTubeProfile.AndroidVR,
                    "IOS" => InnerTubeProfile.IOS,
                    _ => throw new ArgumentException($"unknown client {clientName}"),
                };
                var body = Medley.Providers.YouTube.Json.JsonNav.Parse(rest[1]) as JsonObject ?? new JsonObject();
                var root = await provider.Client.PostAsync(rest[0], body, profile, authenticated: profile == null);
                var text = root.ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = outPath == null });
                if (outPath != null)
                {
                    await File.WriteAllTextAsync(outPath, text);
                    Console.WriteLine($"wrote {text.Length} chars to {outPath}");
                }
                else
                {
                    Console.WriteLine(text);
                }
                break;
            }
            case "whoami":
                if (cookiesFile == null) { Console.WriteLine("pass --cookies <file>"); return 2; }
                var who = await provider.AccountAsync();
                Console.WriteLine($"{who.Name} ({who.Detail ?? "-"}) id: {(who.Id == null ? "-" : "datasync:<redacted>")}");
                break;
            case "library":
            {
                if (cookiesFile == null) { Console.WriteLine("pass --cookies <file>"); return 2; }
                var kind = rest.Count > 0 && Enum.TryParse<LibraryKind>(rest[0], true, out var k) ? k : LibraryKind.LikedSongs;
                var page = await provider.LibraryAsync(kind, null);
                Console.WriteLine($"{kind}: {page.Items.Count} items; more: {page.Continuation != null}");
                foreach (var item in page.Items.Take(20)) Console.WriteLine($"  {Describe(item)}");
                break;
            }
            case "accounts":
            {
                if (cookiesFile == null) { Console.WriteLine("pass --cookies <file>"); return 2; }
                var found = await provider.SwitchableAccountsAsync();
                Console.WriteLine($"picker: {found.Accounts.Count} account(s), authoritative: {found.Authoritative}");
                foreach (var a in found.Accounts)
                {
                    var kind = a.Identity.DelegatedSessionId == null ? "account" : "channel";
                    Console.WriteLine($"  {(a.Identity.IsSelected ? "*" : " ")} [{kind} au={a.Identity.AuthUser}] {a.Info.Name} ({a.Info.Detail ?? "-"})");
                }
                break;
            }
            case "signin-url":
                Console.WriteLine($"start: {WebSignIn.StartUrl}");
                Console.WriteLine($"landing host: {WebSignIn.LandingHost}  cookie url: {WebSignIn.CookieUrl}  domains: *{WebSignIn.CookieDomainSuffix}");
                Console.WriteLine($"required: {string.Join(", ", WebSignIn.RequiredCookies)}");
                break;
            case "transfer-export":
            {
                if (cookiesFile == null) { Console.WriteLine("pass --cookies <file>"); return 2; }
                var transfer = new YouTubeMusicSignInTransfer(provider, new MemoryTransferStore(), persist: false);
                var data = await transfer.ExportSignInAsync();
                if (data == null) { Console.WriteLine("nothing to export"); return 1; }
                var payload = YouTubeMusicSignInPayload.Decode(data);
                Console.WriteLine($"payload: {data.Length} bytes, version {payload.Version}, {payload.Credentials.Cookies.Count} cookies, authUser {payload.Credentials.AuthUser}, account {payload.Account?.Name ?? "-"}");
                break;
            }
            default:
                return Usage();
        }
        return 0;
    }

    /// <summary>A Cookie header, a credentials JSON, a transfer payload, or a Netscape cookies.txt.</summary>
    static YouTubeMusicCredentials? LoadCookies(string path)
    {
        var text = File.ReadAllText(path).Trim();
        if (text.StartsWith('{'))
        {
            var bytes = Encoding.UTF8.GetBytes(text);
            try { return YouTubeMusicSignInPayload.Decode(bytes).Credentials; } catch (FormatException) { }
            return YouTubeMusicCredentials.FromJson(text);
        }
        var lines = text.Split('\n').Select(l => l.TrimEnd('\r')).ToList();
        if (lines.Any(l => l.Split('\t').Length >= 7))
        {
            var cookies = new List<WebCookie>();
            foreach (var line in lines)
            {
                var l = line.StartsWith("#HttpOnly_", StringComparison.Ordinal) ? line["#HttpOnly_".Length..] : line;
                if (l.StartsWith('#')) continue;
                var f = l.Split('\t');
                if (f.Length >= 7) cookies.Add(new WebCookie(f[5], f[6], f[0]));
            }
            return WebSignIn.CredentialsFromCookies(cookies);
        }
        return YouTubeMusicCredentials.FromCookieHeader(text);
    }

    static int Usage()
    {
        Console.WriteLine("usage: medley-probe ytm <search|suggest|link|home|explore|more|album|artist|playlist|radio|radio-seed|lyrics|stream|raw|whoami|library|accounts|signin-url|transfer-export> [args] [--cookies file]");
        return 2;
    }

    static void Section(string title, IEnumerable<string> lines, int limit = 6)
    {
        var list = lines.ToList();
        if (list.Count == 0) return;
        Console.WriteLine($"{title} ({list.Count}):");
        foreach (var line in list.Take(limit)) Console.WriteLine($"  {line}");
    }

    static void PrintShelf(Shelf shelf, int limit = 5)
    {
        var more = shelf.MoreToken is { } m ? $"  more: {Trunc(m, 60)}" : "";
        Console.WriteLine($"[{shelf.Style}] {(shelf.Subtitle is { } s ? s + " / " : "")}{shelf.Title} ({shelf.Items.Count}){more}");
        foreach (var item in shelf.Items.Take(limit)) Console.WriteLine($"    {Describe(item)}");
    }

    static string Trunc(string s, int n) => s.Length <= n ? s : s[..n];

    static string Describe(MediaItem item) => item switch
    {
        MediaItem.TrackItem t => "♪ " + Describe(t.Track),
        MediaItem.AlbumItem a => "◎ " + Describe(a.Album),
        MediaItem.ArtistItem a => "☺ " + Describe(a.Artist),
        MediaItem.PlaylistItem p => "≡ " + Describe(p.Playlist),
        _ => "?",
    };

    static string Describe(Track t)
    {
        var d = t.Duration is { } dur ? $"{(int)dur / 60}:{(int)dur % 60:00}" : "-";
        var album = t.Album is { } a ? $" · {a.Title}" : "";
        var flags = (t.IsExplicit ? " [E]" : "") + (t.IsPlayable ? "" : " [unplayable]");
        return $"{t.Title} — {t.ArtistLine}{album} ({d}) [{t.ProviderID}]{flags}";
    }

    static string Describe(Album a) => $"{a.Title} — {a.ArtistLine} {a.Year?.ToString(CultureInfo.InvariantCulture) ?? ""} {a.Kind} [{a.ProviderID}]";

    static string Describe(Artist a) => $"{a.Name} — {a.Subtitle ?? ""} [{a.ProviderID}]";

    static string Describe(Playlist p) =>
        $"{p.Title} — {p.Owner ?? "-"}{(p.TrackCount is { } c ? $" · {c} tracks" : "")} [{Trunc(p.ProviderID, 48)}]";

    static string Art(Artwork? art) => art == null ? "none" : string.Join("/", art.Images.Select(i => i.Width).OfType<int>());
}
