using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Medley.Core;
using Medley.Core.Sync;
using Medley.Sync.Keys;
using static Medley.Sync.Tests.TestUtil;

namespace Medley.Sync.Tests;

/// <summary>Content sealing (port of ContentSealingTests.swift), and the vectors the Swift code made
/// (Vectors/swift-content-vectors.json, from <c>MEDLEY_CONTENT_VECTORS_OUT=… swift test --filter ContentSealingTests</c>).</summary>
public class ContentSealingTests
{
    private static readonly LibraryKey Key = new(SHA256.HashData(Encoding.UTF8.GetBytes("vector-K1")));
    private static readonly LibraryKey Other = new(SHA256.HashData(Encoding.UTF8.GetBytes("vector-K2")));
    private static readonly LibraryId Library = new("kh7vector0library");
    private static readonly DeviceId Mac = new("jd7vectorholderA");
    private static readonly DeviceId Phone = new("jd7vectorrequestB");

    [Fact]
    public void EveryKindOpensOnlyWhereItWasSealed()
    {
        var plaintext = Encoding.UTF8.GetBytes("{\"title\":\"Get Lucky\"}");
        foreach (var kind in Enum.GetValues<ContentKind>())
        {
            var sealedContent = ContentSealing.Seal(plaintext, kind, Library, Mac, "ctx", Key);
            Assert.Equal(1, sealedContent.V);
            Assert.Equal(Key.Id, sealedContent.KeyId);
            Assert.Equal(plaintext, ContentSealing.Open(sealedContent, kind, Library, Mac, "ctx", Key));
            foreach (var wrong in Enum.GetValues<ContentKind>().Where(k => k != kind))
                Assert.Throws<ContentSealingException>(() => ContentSealing.Open(sealedContent, wrong, Library, Mac, "ctx", Key));
            Assert.Throws<ContentSealingException>(() => ContentSealing.Open(sealedContent, kind, new LibraryId("other"), Mac, "ctx", Key));
            Assert.Throws<ContentSealingException>(() => ContentSealing.Open(sealedContent, kind, Library, Phone, "ctx", Key));
            Assert.Throws<ContentSealingException>(() => ContentSealing.Open(sealedContent, kind, Library, Mac, "ctx2", Key));
            // Under another key: skipped. Naming this key but sealed with another: doesn't open.
            var forged = ContentSealing.Seal(plaintext, kind, Library, Mac, "ctx", Other);
            Assert.Null(ContentSealing.Open(forged, kind, Library, Mac, "ctx", Key));
            Assert.Throws<ContentSealingException>(() => ContentSealing.Open(forged with { KeyId = Key.Id }, kind, Library, Mac, "ctx", Key));
        }
    }

    [Fact]
    public void EverySealHasAFreshNonceAndEachKindItsOwnKey()
    {
        var seals = Enumerable.Range(0, 50).Select(_ => ContentSealing.Seal("same"u8, ContentKind.Playback, Library, Mac, "", Key).Sealed).ToList();
        Assert.Equal(50, seals.Distinct().Count());
        Assert.Equal(50, seals.Select(s => Convert.ToBase64String(Convert.FromBase64String(s)[..12])).Distinct().Count());
        var keys = Enum.GetValues<ContentKind>().Select(k => Convert.ToBase64String(ContentSealing.ContentKey(Key, k))).ToList();
        Assert.Equal(keys.Count, keys.Distinct().Count());
        Assert.DoesNotContain(Convert.ToBase64String(Key.CopyBytes()), keys);
    }

    // MARK: Cross-language vectors

    private static List<Dictionary<string, string>> SwiftVectors()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Vectors", "swift-content-vectors.json");
        var root = JsonDocument.Parse(File.ReadAllText(path)).RootElement.GetProperty("content");
        return root.EnumerateArray().Select(v => v.EnumerateObject().ToDictionary(p => p.Name, p => p.Value.GetString()!)).ToList();
    }

    private static ContentKind KindOf(string name) => Enum.GetValues<ContentKind>().Single(k => ContentSealing.Name(k) == name);

    [Fact]
    public void SwiftVectorsMatchByteForByte()
    {
        var vectors = SwiftVectors();
        Assert.Equal(Enum.GetValues<ContentKind>().Length, vectors.Count);
        foreach (var v in vectors)
        {
            var kind = KindOf(v["kind"]);
            var key = LibraryKey.FromEncoded(v["key"])!;
            var library = new LibraryId(v["libraryId"]);
            var writer = new DeviceId(v["writer"]);
            Assert.Equal(v["keyId"], key.Id);
            Assert.Equal(v["contentKey"], Convert.ToBase64String(ContentSealing.ContentKey(key, kind)));
            Assert.Equal(v["aad"], Convert.ToBase64String(ContentSealing.AssociatedData(kind, library, writer, key.Id, v["context"])));
            // The same plaintext and nonce seal to the same bytes: C# and CryptoKit agree on every step.
            var plaintext = Convert.FromBase64String(v["plaintext"]);
            Assert.Equal(v["sealed"], ContentSealing.Seal(plaintext, kind, library, writer, v["context"], key, Convert.FromBase64String(v["nonce"])).Sealed);
            Assert.Equal(plaintext, ContentSealing.Open(new SealedContent(1, v["keyId"], v["sealed"]), kind, library, writer, v["context"], key));
        }
    }

    [Fact]
    public void SwiftPlaintextsDecodeHere()
    {
        foreach (var v in SwiftVectors())
        {
            var plaintext = Convert.FromBase64String(v["plaintext"]);
            switch (KindOf(v["kind"]))
            {
                case ContentKind.Playback:
                    var playback = JsonSerializer.Deserialize<PlaybackContent>(plaintext, Wire.Options)!;
                    Assert.StartsWith("Get Lucky", playback.Track.Title);
                    Assert.Equal(2, playback.QueueLength);
                    break;
                case ContentKind.Queue or ContentKind.Command:
                    var window = JsonSerializer.Deserialize<QueueWindow>(plaintext, Wire.Options)!;
                    Assert.Equal(2, window.Entries.Count);
                    Assert.True(window.Entries[1].IsUserQueued);
                    break;
                case ContentKind.Result:
                    Assert.Contains("couldn't be loaded", JsonSerializer.Deserialize<ResultContent>(plaintext, Wire.Options)!.Message);
                    break;
                case ContentKind.Setting:
                    Assert.Equal(["daft punk", "Ünïcødé"], JsonSerializer.Deserialize<string[]>(plaintext)!);
                    break;
            }
        }
    }

    /// <summary>What C# seals, for the Swift side to open (<c>MEDLEY_CSHARP_CONTENT_VECTORS_OUT=&lt;path&gt;</c>; the Swift test
    /// <c>csharpVectorsOpen</c> reads it from <c>MEDLEY_CSHARP_CONTENT_VECTORS</c>).</summary>
    [Fact]
    public void WriteCSharpContentVectors()
    {
        var track = new Track { ProviderID = "cs-track-1", Provider = ProviderId.YouTubeMusic, Title = "Windows Sealed Title · Ünïcødé", Duration = 201 };
        var window = new QueueWindow { Entries = [new QueueEntry(track, uid: Guid.Parse("00000000-0000-0000-0000-0000000000C1"))], Index = 0 };
        var cases = new (ContentKind Kind, DeviceId Writer, string Context, byte[] Plaintext)[]
        {
            (ContentKind.Playback, Phone, "", JsonSerializer.SerializeToUtf8Bytes(new PlaybackContent(track, 0, 1), Wire.Options)),
            (ContentKind.Queue, Phone, "", JsonSerializer.SerializeToUtf8Bytes(window, Wire.Options)),
            (ContentKind.Command, Phone, Mac.Value, JsonSerializer.SerializeToUtf8Bytes(window, Wire.Options)),
            (ContentKind.Result, Phone, "jh7csharpcommand", JsonSerializer.SerializeToUtf8Bytes(new ResultContent("\"Windows Sealed Title\" couldn't be loaded."), Wire.Options)),
            (ContentKind.Setting, Phone, SettingKeys.RecentSearches, Encoding.UTF8.GetBytes(SettingsSync.Json(new[] { "windows search", "Ünïcødé" }))),
        };
        var vectors = cases.Select(c =>
        {
            var sealedContent = ContentSealing.Seal(c.Plaintext, c.Kind, Library, c.Writer, c.Context, Key);
            Assert.Equal(c.Plaintext, ContentSealing.Open(sealedContent, c.Kind, Library, c.Writer, c.Context, Key));
            return new Dictionary<string, string>
            {
                ["kind"] = ContentSealing.Name(c.Kind), ["libraryId"] = Library.Value, ["writer"] = c.Writer.Value, ["context"] = c.Context,
                ["key"] = Key.Encoded, ["keyId"] = Key.Id, ["plaintext"] = Convert.ToBase64String(c.Plaintext), ["sealed"] = sealedContent.Sealed,
            };
        }).ToList();
        if (Environment.GetEnvironmentVariable("MEDLEY_CSHARP_CONTENT_VECTORS_OUT") is { Length: > 0 } output)
            File.WriteAllText(output, JsonSerializer.Serialize(new Dictionary<string, object> { ["content"] = vectors }, new JsonSerializerOptions { WriteIndented = true }));
    }
}

/// <summary>Real <see cref="SyncService"/>s through <see cref="FakeKeyServer"/>, which keeps content as the backend does
/// (sealed blobs only): devices with the key read each other, one without it sees only where others are, and nothing
/// readable reaches the server (port of SealedContentServiceTests.swift).</summary>
public class SealedContentServiceTests : ServiceTests
{
    private const string Title = "Get Lucky (Windows Sealed Title)";
    private const string Artist = "Daft Punk Sealed Artist";
    private const string ArtworkUrl = "https://lh3.googleusercontent.com/sealed-windows-artwork";
    private const string Search = "sealed windows search";

    private static QueueWindow Window() => new()
    {
        Entries =
        [
            new QueueEntry(new Track { ProviderID = "sealedTrackIdW1", Provider = ProviderId.YouTubeMusic, Title = Title, Artists = [new ArtistRef { Name = Artist }],
                                       Artwork = Artwork.FromUrl(new Uri(ArtworkUrl)), Duration = 240 }),
            new QueueEntry(new Track { ProviderID = "sealedTrackIdW2", Provider = ProviderId.YouTubeMusic, Title = "Second Windows Song" }),
        ],
        Index = 0,
    };

    private static PlaybackAnchor Anchor(SyncService s, bool playing = true) =>
        new() { PositionMs = 133_000, PositionAt = s.Clock.Now(), IsPlaying = playing, Rate = 1, DurationMs = 240_000, Volume = 0.5 };

    private static void AssertNoPlaintext(FakeKeyServer server)
    {
        var sent = string.Join("", new[] { "playback:publish", "commands:send", "commands:ack", "settings:put", "keys:rotate" }
            .SelectMany(p => server.CallsTo(p)).Select(c => c.Args.JsonString()));
        var dump = server.ContentDump + sent;
        foreach (var text in new[] { Title, Artist, ArtworkUrl, "googleusercontent", Search, "sealedTrackIdW", "Second Windows Song", "couldn't be loaded" })
            Assert.DoesNotContain(text, dump);
    }

    /// <summary><paramref name="asker"/> gets the key from whichever of <paramref name="holders"/> answered its exchange
    /// (the first answer wins, so with two holders either may).</summary>
    private async Task Approve(SyncService asker, params SyncService[] holders)
    {
        await SignIn(asker);
        Assert.True(await Eventually(() => holders.Any(h => h.KeyRequests.Any(r => r.Device.Id == asker.SelfId)), 8000));
        var holder = holders.First(h => h.KeyRequests.Any(r => r.Device.Id == asker.SelfId));
        await holder.AllowKeyAsync(await On(holder, () => holder.KeyRequests.First(r => r.Device.Id == asker.SelfId)));
        Assert.True(await WaitUntil(asker, () => Comparison(asker) is { Allowed: true }));
        asker.ConfirmKeyCode();
        Assert.True(await WaitUntil(asker, () => asker.KeyStatus is KeyStatus.Available));
    }

    [Fact]
    public async Task DevicesWithTheKeyReadEachOtherAndTheServerSeesNone()
    {
        var server = new FakeKeyServer();
        var (mac, phone) = await TwoHolders(server);
        var macId = (await On(mac, () => mac.SelfId))!.Value;
        await mac.PublishAsync(Anchor(mac), Window());
        Assert.True(await WaitUntil(phone, () => phone.Playback.TryGetValue(macId, out var r) && r.Track?.Title == Title));
        var row = await On(phone, () => phone.Playback[macId]);
        Assert.Equal(PlaybackContentState.Open, row.Content);
        Assert.Equal(0, row.Index);
        Assert.Equal(2, row.QueueLength);
        var fetched = await phone.FetchQueueAsync(macId);
        Assert.Equal([Title, "Second Windows Song"], fetched!.Entries.Select(e => e.Track.Title));

        IncomingCommand? arrived = null;
        mac.CommandHandler = c =>
        {
            arrived = c;
            return Task.FromResult(CommandResult.Failure(CommandFailure.PlaybackFailed, $"\"{Title}\" couldn't be loaded on Leo's Mac."));
        };
        var window = Window();
        var id = await phone.SendAsync(SyncCommand.TakeOver(new HandoffState { Queue = window.Entries, Index = 0, Anchor = Anchor(phone) }), macId);
        var result = await phone.WaitForAckAsync(id, TimeSpan.FromSeconds(10));
        Assert.Equal(Title, arrived?.Command.State?.Queue[0].Track.Title);
        Assert.False(result.Ok);
        Assert.Equal(CommandFailure.PlaybackFailed, result.Reason);
        Assert.Equal($"\"{Title}\" couldn't be loaded on Leo's Mac.", result.Message);

        string? searches = null;
        await phone.Settings.ObserveAsync(SettingKeys.RecentSearches, () => null, text => searches = text);
        await mac.Settings.ObserveAsync(SettingKeys.RecentSearches, () => SettingsSync.Json(new[] { Search }), _ => { });
        Assert.True(await WaitUntil(phone, () => searches?.Contains(Search) == true));
        AssertNoPlaintext(server);
    }

    [Fact]
    public async Task ADeviceWithoutTheKeySeesWhereOthersPlayAndCanStillControlThem()
    {
        var server = new FakeKeyServer();
        var mac = Device(server, "Leo's Mac");
        await SignIn(mac);
        Assert.True(await WaitUntil(mac, () => mac.KeyStatus is KeyStatus.Available));
        var macId = (await On(mac, () => mac.SelfId))!.Value;
        await mac.PublishAsync(Anchor(mac), Window());
        var pc = Device(server, "Leo's PC");   // never approved
        await SignIn(pc);
        Assert.True(await WaitUntil(pc, () => pc.Playback.ContainsKey(macId)));
        var row = await On(pc, () => pc.Playback[macId]);
        Assert.Null(row.Track);
        Assert.Null(row.TrackLine);
        Assert.Equal(PlaybackContentState.Sealed, row.Content);
        Assert.True(row.Anchor.IsPlaying);
        Assert.False(pc.CanSealContent);
        await pc.PublishAsync(Anchor(pc, playing: false), Window());
        var pcId = (await On(pc, () => pc.SelfId))!.Value;
        Assert.True(await WaitUntil(mac, () => mac.Playback.TryGetValue(pcId, out var r) && r.Content == PlaybackContentState.None));

        var paused = false;
        mac.CommandHandler = c => { if (c.Command.Kind == SyncCommandKind.Pause) paused = true; return Task.FromResult(CommandResult.Success); };
        var pause = await pc.SendAsync(SyncCommand.Pause, macId);
        Assert.True((await pc.WaitForAckAsync(pause, TimeSpan.FromSeconds(10))).Ok);
        Assert.True(paused);
        var e1 = await Assert.ThrowsAsync<SyncException>(() => pc.FetchQueueAsync(macId));
        Assert.Equal(SyncErrorKind.NeedsKey, e1.Kind);
        var w = Window();
        var e2 = await Assert.ThrowsAsync<SyncException>(() => pc.SendAsync(SyncCommand.TakeOver(new HandoffState { Queue = w.Entries, Index = 0, Anchor = Anchor(pc) }), macId));
        Assert.Equal(SyncErrorKind.NeedsKey, e2.Kind);
        pc.CommandHandler = _ => throw new InvalidOperationException("a sealed takeover reached the handler");
        var toPc = await mac.SendAsync(SyncCommand.TakeOver(new HandoffState { Queue = w.Entries, Index = 0, Anchor = Anchor(mac) }), pcId);
        var answer = await mac.WaitForAckAsync(toPc, TimeSpan.FromSeconds(10));
        Assert.Equal(CommandFailure.NeedsKey, answer.Reason);
        Assert.Contains("Leo's PC doesn't have your sign-in key", answer.Message);
        Assert.Null(await On(pc, () => pc.SettingEntries));
        AssertNoPlaintext(server);

        await Approve(pc, mac);
        Assert.True(await WaitUntil(pc, () => pc.Playback.TryGetValue(macId, out var r) && r.Track?.Title == Title));
    }

    [Fact]
    public async Task AfterARotationTheRemainingDevicesStillReadPlaybackAndSettings()
    {
        var server = new FakeKeyServer();
        var (mac, phone) = await TwoHolders(server);
        var old = Device(server, "Old PC");
        await Approve(old, mac, phone);
        var phoneId = (await On(phone, () => phone.SelfId))!.Value;
        var phonePlayer = new FakePlayer { Entries = Window().Entries.ToList(), CurrentIndex = 0, State = SyncPlayerState.Playing };
        var coordinator = new SyncCoordinator(phone, phonePlayer, phone.Actor);
        await coordinator.AttachAsync();
        Assert.True(await WaitUntil(mac, () => mac.Playback.TryGetValue(phoneId, out var r) && r.Track?.Title == Title));
        await phone.Settings.ObserveAsync(SettingKeys.RecentSearches, () => SettingsSync.Json(new[] { Search }), _ => { });
        await mac.Settings.ObserveAsync(SettingKeys.RecentSearches, () => null, _ => { });
        Assert.True(await WaitUntil(mac, () => mac.SettingEntries?.Any(e => e.Value.Contains(Search)) == true));
        var before = (await On(mac, () => mac.LibraryKey))!.Id;

        await mac.RemoveAsync((await On(old, () => old.SelfId))!.Value);
        Assert.True(await Eventually(() => server.KeyId is { } k && k != before, 10_000));
        var after = server.KeyId!;
        Assert.True(await WaitUntil(mac, () => mac.LibraryKey?.Id == after, 10_000));
        Assert.True(await WaitUntil(phone, () => phone.LibraryKey?.Id == after, 10_000));
        // The phone published again under the new key; the settings were re-sealed and still open on both.
        Assert.True(await Eventually(() => server.ContentDump.Contains(after) && !server.ContentDump.Contains(before), 10_000));
        Assert.True(await WaitUntil(mac, () => mac.Playback.TryGetValue(phoneId, out var r) && r.Track?.Title == Title));
        Assert.True(await WaitUntil(phone, () => phone.SettingEntries?.Any(e => e.Value.Contains(Search)) == true));
        Assert.True(await WaitUntil(mac, () => mac.SettingEntries?.Any(e => e.Value.Contains(Search)) == true));
        AssertNoPlaintext(server);
        await coordinator.DetachAsync();
    }
}
