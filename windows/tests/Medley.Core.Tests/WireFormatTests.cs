using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization.Metadata;
using Medley.Core.Mock;
using Medley.Core.Support;
using Medley.Core.Sync;
using static Medley.Core.Tests.T;

namespace Medley.Core.Tests;

/// <summary>
/// The JSON the sync server stores and relays must be exactly what the Swift apps write. The fixtures are written by
/// scripts/windows-fixtures/generate.sh with the real Swift model sources and JSONEncoder; each test decodes one,
/// encodes it again, and builds the same value in C#, and both encodings must equal the fixture as JSON (Swift's key
/// order is unspecified, so the comparison is structural, with no extra or missing keys and the same number values).
/// </summary>
public class WireFormatTests
{
    private static readonly MedleyJsonContext Ctx = MedleyJsonContext.Default;
    private static readonly Guid Uid = Guid.Parse("E621E1F8-C36C-495A-93FC-0C247A3E6E5F");
    private static readonly Guid Uid2 = Guid.Parse("0B1D3C5A-7E9F-4A2B-8C6D-1E3F5A7B9C0D");

    private static readonly Track Full = new()
    {
        ProviderID = "dQw4w9WgXcQ", Provider = ProviderId.YouTubeMusic, Title = "Never Gonna Give You Up",
        Artists = [new ArtistRef("UCuAXFkgsw1L7xaCfnd5JJOw", "Rick Astley"), new ArtistRef(null, "Guest")],
        Album = new AlbumRef("MPREb_abc", "Whenever You Need Somebody"),
        Duration = 213.5,
        Artwork = new Artwork([
            new ArtworkImage(new Uri("https://lh3.googleusercontent.com/abc=w120-h120"), 120, 120),
            new ArtworkImage(new Uri("https://lh3.googleusercontent.com/abc=w544-h544")),
        ]),
        IsExplicit = true, IsPlayable = true, TrackNumber = 1,
        Extra = new Dictionary<string, string> { ["setVideoId"] = "56B44F6D10557CC6" },
    };

    private static readonly Track Minimal = new() { ProviderID = "4uLU6hMCjMI75M1A2tKUQC", Provider = ProviderId.Spotify, Title = "Minimal" };

    private static readonly Album AlbumValue = new()
    {
        ProviderID = "MPREb_abc", Provider = ProviderId.YouTubeMusic, Title = "Whenever You Need Somebody",
        Artists = [new ArtistRef("UC1", "Rick Astley")], Year = 1987, Kind = AlbumKind.Album, TrackCount = 10,
    };

    private static readonly QueueEntry Entry = new(Full, isUserQueued: true, context: PlaybackContext.ForAlbum(AlbumValue), uid: Uid);
    private static readonly QueueEntry AutoEntry = new(Minimal, isAutoplay: true, context: PlaybackContext.Autoplay, uid: Uid2);

    private static readonly PlaybackAnchor Anchor = new()
    {
        PositionMs = 72000, PositionAt = 1_800_000_000_123, IsPlaying = true, Rate = 1, DurationMs = 297000, Volume = 0.8,
        Shuffle = false, Repeat = RepeatMode.All,
    };

    private static readonly QueueWindow Window = new() { Entries = [Entry, AutoEntry], Index = 1 };

    /// <summary>Decode the fixture, re-encode it, and encode <paramref name="built"/>: all three must be the same JSON.</summary>
    private static T RoundTrip<T>(string fixture, JsonTypeInfo<T> info, T built)
    {
        var text = Fixture(fixture);
        var expected = JsonNode.Parse(text);
        var decoded = MedleyJson.Deserialize(text, info)!;
        AssertSameJson(expected, MedleyJson.Serialize(decoded, info));
        AssertSameJson(expected, MedleyJson.Serialize(built, info));
        Assert.Equal(built, decoded);
        return decoded;
    }

    private static void AssertSameJson(JsonNode? expected, string actualText)
    {
        var actual = JsonNode.Parse(actualText);
        Assert.True(JsonNode.DeepEquals(expected, actual), $"expected\n{expected?.ToJsonString()}\nactual\n{actualText}");
        // Numbers must also be written the same way (213.5, 120, never 120.0), so compare the canonical text per value.
        Assert.Equal(Canonical(expected), Canonical(actual));
    }

    /// <summary>Keys sorted, numbers as their raw text.</summary>
    private static string Canonical(JsonNode? node) => node switch
    {
        null => "null",
        JsonObject o => "{" + string.Join(",", o.OrderBy(p => p.Key, StringComparer.Ordinal).Select(p => $"\"{p.Key}\":{Canonical(p.Value)}")) + "}",
        JsonArray a => "[" + string.Join(",", a.Select(Canonical)) + "]",
        _ => node.ToJsonString(),
    };

    [Fact] public void TrackFull() => RoundTrip("track-full", Ctx.Track, Full);

    [Fact]
    public void TrackMinimalLeavesOutNilOptionalsAndKeepsEmptyExtra()
    {
        RoundTrip("track-minimal", Ctx.Track, Minimal);
        var json = JsonNode.Parse(MedleyJson.Serialize(Minimal, Ctx.Track))!.AsObject();
        Assert.False(json.ContainsKey("album"));
        Assert.False(json.ContainsKey("duration"));
        Assert.False(json.ContainsKey("artwork"));
        Assert.False(json.ContainsKey("trackNumber"));
        Assert.Equal("{}", json["extra"]!.ToJsonString());
        Assert.Equal("[]", json["artists"]!.ToJsonString());
    }

    [Fact] public void ContextAlbum() => RoundTrip("context-album", Ctx.PlaybackContext, PlaybackContext.ForAlbum(AlbumValue));
    [Fact] public void ContextRadio() => RoundTrip("context-radio", Ctx.PlaybackContext, PlaybackContext.Radio("Rick Astley", "RDAMVM1", ProviderId.YouTubeMusic));
    [Fact] public void ContextAutoplay() => RoundTrip("context-autoplay", Ctx.PlaybackContext, PlaybackContext.Autoplay);

    [Fact]
    public void QueueEntryWritesUppercaseUuid()
    {
        RoundTrip("queue-entry", Ctx.QueueEntry, Entry);
        Assert.Contains("\"uid\":\"E621E1F8-C36C-495A-93FC-0C247A3E6E5F\"", MedleyJson.Serialize(Entry, Ctx.QueueEntry));
    }

    [Fact] public void QueueEntryAutoplay() => RoundTrip("queue-entry-autoplay", Ctx.QueueEntry, AutoEntry);
    [Fact] public void QueueEntryNoContext() => RoundTrip("queue-entry-no-context", Ctx.QueueEntry, new QueueEntry(Minimal, uid: Uid2));

    [Fact]
    public void QueueEntryDecodesOlderPayloads()
    {
        var json = JsonNode.Parse(MedleyJson.Serialize(new QueueEntry(Minimal, uid: Uid), Ctx.QueueEntry))!.AsObject();
        json.Remove("isUserQueued");
        json.Remove("isAutoplay");
        json.Remove("context");
        var decoded = MedleyJson.Deserialize(json.ToJsonString(), Ctx.QueueEntry)!;
        Assert.Equal(Uid, decoded.Uid);
        Assert.False(decoded.IsUserQueued);
        Assert.False(decoded.IsAutoplay);
    }

    [Fact]
    public void MissingOrNullCollectionsDecodeEmpty()
    {
        // Source-generated init-only properties get null for absent members; the models turn that into empty.
        var t = MedleyJson.Deserialize("""{"providerID":"a","provider":"spotify","title":"x","artists":null}""", Ctx.Track)!;
        Assert.Empty(t.Artists);
        Assert.Empty(t.Extra);
        Assert.Equal("{}", JsonNode.Parse(MedleyJson.Serialize(t, Ctx.Track))!["extra"]!.ToJsonString());
        var snapshot = MedleyJson.Deserialize("""{"version":1,"position":0,"shuffle":false,"repeatMode":"off","savedAt":0}""", Ctx.PlayerSnapshot)!;
        Assert.Empty(snapshot.Queue);
        Assert.Empty(snapshot.RecentlyPlayed);
        Assert.Empty(MedleyJson.Deserialize("""{"index":0}""", Ctx.QueueWindow)!.Entries);
        Assert.Empty(MedleyJson.Deserialize("""{}""", Ctx.Lyrics)!.Lines);
    }

    [Fact]
    public void QueueEntryWithoutUidIsRejected() =>
        Assert.ThrowsAny<JsonException>(() => MedleyJson.Deserialize("""{"track":{"providerID":"a","provider":"spotify","title":"x"}}""", Ctx.QueueEntry));

    [Fact] public void Anchor_() => RoundTrip("anchor", Ctx.PlaybackAnchor, Anchor);

    [Fact]
    public void AnchorWithoutDuration() => RoundTrip("anchor-no-duration", Ctx.PlaybackAnchor, new PlaybackAnchor
    {
        PositionMs = 1500.5, PositionAt = 1_800_000_000_000, IsPlaying = false, Volume = 1, Shuffle = true, Repeat = RepeatMode.Off,
    });

    [Fact]
    public void AnchorLivePosition()
    {
        Assert.Equal(74, Anchor.Position(Anchor.PositionAt + 2000), 3);
        Assert.Equal(297, Anchor.Position(Anchor.PositionAt + 10_000_000), 3);
        Assert.Equal(72, (Anchor with { IsPlaying = false }).Position(Anchor.PositionAt + 5000), 3);
    }

    [Fact] public void QueueWindow_() => RoundTrip("queue-window", Ctx.QueueWindow, Window);

    [Fact]
    public void QueueWindowAroundTheCurrentEntry()
    {
        var queue = MakeTracks(200).Select(t => new QueueEntry(t)).ToList();
        var w = QueueWindow.Around(queue, 50)!;
        Assert.Equal(20 + 1 + 100, w.Entries.Count);
        Assert.Equal(20, w.Index);
        Assert.Equal(queue[50], w.Current);
        Assert.Null(QueueWindow.Around(queue, null));
        Assert.Equal(0, QueueWindow.Around(queue, 0)!.Index);
    }

    [Fact] public void CommandPlay() => RoundTrip("command-play", Ctx.SyncCommand, SyncCommand.Play);
    [Fact] public void CommandSeek() => RoundTrip("command-seek", Ctx.SyncCommand, SyncCommand.Seek(12345));
    [Fact] public void CommandVolume() => RoundTrip("command-volume", Ctx.SyncCommand, SyncCommand.SetVolumeTo(0.25));

    [Fact]
    public void CommandTakeOver() =>
        RoundTrip("command-takeover", Ctx.SyncCommand, SyncCommand.TakeOver(new HandoffState { Queue = Window.Entries, Index = Window.Index, Anchor = Anchor }));

    [Fact] public void CommandResultOk() => RoundTrip("command-result-ok", Ctx.CommandResult, CommandResult.Success);
    [Fact] public void CommandResultMessage() => RoundTrip("command-result-message", Ctx.CommandResult, new CommandResult(false, "Nothing to play"));
    [Fact] public void DeviceInfo_() => RoundTrip("device-info", Ctx.DeviceInfo, new DeviceInfo("Leo's Mac", DevicePlatform.Mac, "Mac16,10", "0.1"));
    [Fact] public void Lyrics_() => RoundTrip("lyrics", Ctx.Lyrics, new Lyrics([new LyricLine(12.5, "First line"), new LyricLine(null, "")], "LRCLIB"));
    [Fact] public void MediaItemAlbum() => RoundTrip("media-item-album", Ctx.MediaItem, MediaItem.Of(AlbumValue));
    [Fact] public void MediaItemTrack() => RoundTrip("media-item-track", Ctx.MediaItem, MediaItem.Of(Minimal));
    [Fact] public void AccountInfo_() => RoundTrip("account-info", Ctx.AccountInfo, new AccountInfo("Sample Listener", new Uri("https://example.com/a.png"), "Premium", "abc"));

    [Fact]
    public void PlayerSnapshotUsesSwiftDates()
    {
        var played = new PlayedTrack(Full, DateTimeOffset.FromUnixTimeSeconds(1_800_000_000), PlaybackContext.ForAlbum(AlbumValue));
        var snapshot = new PlayerSnapshot
        {
            Queue = [Entry, AutoEntry], CurrentIndex = 0, Position = 42.25, Shuffle = true, RepeatMode = RepeatMode.One,
            OriginalOrder = [Uid2, Uid], RecentlyPlayed = [played], SavedAt = DateTimeOffset.FromUnixTimeSeconds(1_800_000_100),
        };
        var decoded = RoundTrip("player-snapshot", Ctx.PlayerSnapshot, snapshot);
        // Seconds since 2001-01-01.
        Assert.Contains("\"savedAt\":821692900", MedleyJson.Serialize(decoded, Ctx.PlayerSnapshot));
    }

    [Fact]
    public void EmptyPlayerSnapshot() => RoundTrip("player-snapshot-empty", Ctx.PlayerSnapshot, new PlayerSnapshot
    {
        Position = 0, SavedAt = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000),
    });

    // Settings are JSON text compared as text by SettingsSync, so these must match Swift byte for byte.

    [Fact] public void SettingBool() => Assert.Equal(Fixture("setting-bool"), MedleyJson.EncodeSetting(true, Ctx.Boolean));
    [Fact] public void SettingDouble() => Assert.Equal(Fixture("setting-double"), MedleyJson.EncodeSetting(2.5, Ctx.Double));
    [Fact] public void SettingWholeDouble() => Assert.Equal(Fixture("setting-double-whole"), MedleyJson.EncodeSetting(12.0, Ctx.Double));
    [Fact] public void SettingInt() => Assert.Equal(Fixture("setting-int"), MedleyJson.EncodeSetting(30, Ctx.Int32));

    [Fact]
    public void SettingRecentSearchesEscapeLikeSwift() =>
        Assert.Equal(Fixture("setting-recent-searches"), MedleyJson.EncodeSetting(new List<string> { "daft punk", "AC/DC", "Beyoncé", "say \"hi\"" }, Ctx.ListString));

    [Fact]
    public void SettingStringsEscapeExactlyLikeSwift() =>
        Assert.Equal(Fixture("setting-tricky-strings"), MedleyJson.EncodeSetting(
            new List<string> { "line\u2028sep", "para\u2029sep", "tab\tend", "ctl\u0001\u001f", "bs\bff\f", "nl\nret\r", "del\u007f", "é🎧", "<a&b>'" },
            Ctx.ListString));

    [Theory]
    [InlineData("setting-small-double", 1e-05)]
    [InlineData("setting-big-double", 1.5e20)]
    [InlineData("setting-fraction-double", 0.1)]
    public void SettingNumbersWriteLikeSwift(string fixture, double value) =>
        Assert.Equal(Fixture(fixture), MedleyJson.EncodeSetting(value, Ctx.Double));

    [Fact]
    public void ExponentCaseIsOnlyChangedOutsideStrings() =>
        Assert.Equal("[\"E=mc2\"]", MedleyJson.EncodeSetting(new List<string> { "E=mc2" }, Ctx.ListString));

    [Fact]
    public void SwiftEscapesKeepEmojiAndEscapedBackslashes()
    {
        Assert.Equal("[\"🎧 mix\"]", MedleyJson.EncodeSetting(new List<string> { "🎧 mix" }, Ctx.ListString));
        Assert.Equal("[\"a\\\\\\/b\"]", MedleyJson.EncodeSetting(new List<string> { "a\\/b" }, Ctx.ListString));
    }
}

/// <summary>The C# mock catalogs are built exactly as the Swift ones: same ids, titles, lengths, picks, bios and lyrics
/// (compared with the Swift dumps in Fixtures/catalog-*.json).</summary>
public class MockCatalogParityTests
{
    private static readonly MedleyJsonContext Ctx = MedleyJsonContext.Default;

    [Theory]
    [InlineData(MockDataset.Sample, ProviderId.YouTubeMusic)]
    [InlineData(MockDataset.Sample, ProviderId.Spotify)]
    [InlineData(MockDataset.Demo, ProviderId.YouTubeMusic)]
    [InlineData(MockDataset.Demo, ProviderId.Spotify)]
    public void MatchesSwift(MockDataset dataset, ProviderId provider)
    {
        var c = new MockCatalog(provider, dataset);
        var expected = JsonNode.Parse(Fixture($"catalog-{(dataset == MockDataset.Demo ? "demo" : "sample")}-{provider.RawValue()}"))!.AsObject();
        Section(expected, "artists", new JsonArray(c.Artists.Select(a => Node(a, Ctx.Artist)).ToArray()));
        Section(expected, "albums", new JsonArray(c.Albums.Select(a => Node(a, Ctx.Album)).ToArray()));
        Section(expected, "albumTracks", Obj(c.AlbumTracks.ToDictionary(kv => kv.Key, kv => (JsonNode?)new JsonArray(kv.Value.Select(t => Node(t, Ctx.Track)).ToArray()))));
        Section(expected, "playlists", new JsonArray(c.Playlists.Select(p => Node(p, Ctx.Playlist)).ToArray()));
        Section(expected, "playlistTracks", Obj(c.PlaylistTracks.ToDictionary(kv => kv.Key, kv => (JsonNode?)new JsonArray(kv.Value.Select(t => (JsonNode)JsonValue.Create(t.Id)!).ToArray()))));
        Section(expected, "bios", Obj(c.Bios.ToDictionary(kv => kv.Key, kv => (JsonNode?)JsonValue.Create(kv.Value))));
        Section(expected, "lyrics", Obj(c.AllTracks.Take(12).ToDictionary(t => t.Id, t => c.Lyrics(t) is { } l ? Node(l, Ctx.Lyrics) : null)));
    }

    private static JsonNode? Node<TValue>(TValue value, JsonTypeInfo<TValue> info) => JsonNode.Parse(MedleyJson.Serialize(value, info));

    private static JsonObject Obj(Dictionary<string, JsonNode?> d)
    {
        var o = new JsonObject();
        foreach (var (k, v) in d) o[k] = v;
        return o;
    }

    private static void Section(JsonObject expected, string key, JsonNode actual)
    {
        var e = expected[key];
        if (!JsonNode.DeepEquals(e, actual))
        {
            // Point at the first differing element so a drift is easy to find.
            if (e is JsonArray ea && actual is JsonArray aa)
            {
                for (var i = 0; i < Math.Min(ea.Count, aa.Count); i++)
                    Assert.True(JsonNode.DeepEquals(ea[i], aa[i]), $"{key}[{i}]\nswift  {ea[i]?.ToJsonString()}\nc#     {aa[i]?.ToJsonString()}");
                Assert.Equal(ea.Count, aa.Count);
            }
            if (e is JsonObject eo && actual is JsonObject ao)
            {
                foreach (var (k, v) in eo)
                    Assert.True(JsonNode.DeepEquals(v, ao[k]), $"{key}.{k}\nswift  {v?.ToJsonString()}\nc#     {ao[k]?.ToJsonString()}");
                Assert.Equal(eo.Count, ao.Count);
            }
            Assert.Fail($"{key} differs");
        }
    }
}
