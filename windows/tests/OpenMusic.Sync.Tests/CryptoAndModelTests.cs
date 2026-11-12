using System.Text;
using System.Text.Json;
using OpenMusic.Core;
using OpenMusic.Core.Sync;
using OpenMusic.Sync.Convex;
using OpenMusic.Sync.Keys;

namespace OpenMusic.Sync.Tests;

/// <summary>Ports of KeyGrantTests.swift and ConvexValueTests.swift.</summary>
public class CryptoAndModelTests
{
    private static readonly LibraryId Lib = new("lib");
    private static readonly DeviceId Phone = new("phone");
    private static readonly DeviceId Mac = new("mac");

    private static KeyExchange.Transcript T(DeviceKeyPair requester, byte[] nB, DeviceKeyPair holder, byte[] nA) =>
        new(Lib, Phone, requester.PublicKey, nB, Mac, holder.PublicKey, nA);

    [Fact]
    public void BothDevicesShowTheSameCodeAndEveryFieldChangesIt()
    {
        var a = DeviceKeyPair.Generate();
        var b = DeviceKeyPair.Generate();
        var nA = KeyExchange.Nonce();
        var nB = KeyExchange.Nonce();
        var t = T(b, nB, a, nA);
        Assert.Matches(@"^\d{3} \d{3}$", t.Code);
        Assert.Equal(t.Code, T(b, nB, a, nA).Code);
        var variants = new[]
        {
            t with { LibraryId = new LibraryId("lib2") }, t with { Requester = new DeviceId("phone2") }, t with { RequesterKey = DeviceKeyPair.Generate().PublicKey },
            t with { RequesterNonce = KeyExchange.Nonce() }, t with { Holder = new DeviceId("mac2") }, t with { HolderKey = DeviceKeyPair.Generate().PublicKey },
            t with { HolderNonce = KeyExchange.Nonce() },
        };
        foreach (var v in variants) Assert.False(v.Digest.AsSpan().SequenceEqual(t.Digest));
        // Length prefixes: moving bytes between adjacent fields changes the digest.
        var shifted = t with { LibraryId = new LibraryId("li"), Requester = new DeviceId("bphone") };
        Assert.False(shifted.Digest.AsSpan().SequenceEqual(t.Digest));
    }

    [Fact]
    public void AHolderHasOneNoncePerRequestAndEveryFieldChangesIt()
    {
        var a = DeviceKeyPair.Generate();
        var b = DeviceKeyPair.Generate().PublicKey;
        var c = Convert.ToBase64String(KeyExchange.Nonce());
        var n = KeyExchange.AnswerNonce(a, Mac, Lib, Phone, b, c)!;
        Assert.Equal(32, n.Length);
        Assert.Equal(n, KeyExchange.AnswerNonce(a, Mac, Lib, Phone, b, c));
        Assert.NotEqual(n, KeyExchange.AnswerNonce(DeviceKeyPair.Generate(), Mac, Lib, Phone, b, c));
        Assert.NotEqual(n, KeyExchange.AnswerNonce(a, new DeviceId("mac2"), Lib, Phone, b, c));
        Assert.NotEqual(n, KeyExchange.AnswerNonce(a, Mac, new LibraryId("lib2"), Phone, b, c));
        Assert.NotEqual(n, KeyExchange.AnswerNonce(a, Mac, Lib, new DeviceId("ipad"), b, c));
        Assert.NotEqual(n, KeyExchange.AnswerNonce(a, Mac, Lib, Phone, DeviceKeyPair.Generate().PublicKey, c));
        Assert.NotEqual(n, KeyExchange.AnswerNonce(a, Mac, Lib, Phone, b, Convert.ToBase64String(KeyExchange.Nonce())));
        Assert.Null(KeyExchange.AnswerNonce(a, Mac, Lib, Phone, "not-a-key", c));
        Assert.Null(KeyExchange.AnswerNonce(a, Mac, Lib, Phone, b, Convert.ToBase64String(new byte[31])));
    }

    [Fact]
    public void TheCommitmentBindsTheKeyAndTheNonce()
    {
        var b = DeviceKeyPair.Generate();
        var n = KeyExchange.Nonce();
        var c = KeyExchange.Commitment(b.PublicKey, n);
        Assert.Equal(c, KeyExchange.Commitment(b.PublicKey, n));
        Assert.NotEqual(c, KeyExchange.Commitment(b.PublicKey, KeyExchange.Nonce()));
        Assert.NotEqual(c, KeyExchange.Commitment(DeviceKeyPair.Generate().PublicKey, n));
        Assert.Null(KeyExchange.Commitment(b.PublicKey, new byte[16]));
        Assert.Null(KeyExchange.Commitment("bad", n));
    }

    [Fact]
    public void AServerInTheMiddleGetsTwoDifferentCodes()
    {
        var a = DeviceKeyPair.Generate();
        var b = DeviceKeyPair.Generate();
        var server = DeviceKeyPair.Generate();
        var nB = KeyExchange.Nonce();
        var nA = KeyExchange.Nonce();
        // B records the server's answer; A records the server's commitment: two transcripts.
        var onB = T(b, nB, server, KeyExchange.Nonce()) with { Holder = Mac };
        var onA = T(server, KeyExchange.Nonce(), a, nA) with { Requester = Phone };
        Assert.NotEqual(onA.Code, onB.Code);
    }

    [Fact]
    public void AGrantOpensOnlyForTheRecordedExchangeAndOnlyFromItsHolder()
    {
        var a = DeviceKeyPair.Generate();
        var b = DeviceKeyPair.Generate();
        var key = LibraryKey.Generate();
        var t = T(b, KeyExchange.Nonce(), a, KeyExchange.Nonce());
        var wrapped = KeyExchange.Wrap(key, t, a);
        Assert.Equal(key, KeyExchange.Unwrap(wrapped, t, b, key.Id));
        Assert.Throws<SyncException>(() => KeyExchange.Unwrap(wrapped, t with { HolderNonce = KeyExchange.Nonce() }, b, key.Id));
        Assert.Throws<SyncException>(() => KeyExchange.Unwrap(wrapped, t, b, LibraryKey.Generate().Id));
        Assert.Throws<SyncException>(() => KeyExchange.Unwrap(wrapped, t, DeviceKeyPair.Generate(), key.Id));
        // Someone else claiming to be the holder (its own key pair in the transcript) can't make a grant for A's.
        var mallory = DeviceKeyPair.Generate();
        Assert.Throws<SyncException>(() => KeyExchange.Wrap(key, t, mallory));
        var forged = KeyExchange.Wrap(key, t with { HolderKey = mallory.PublicKey }, mallory);
        Assert.Throws<SyncException>(() => KeyExchange.Unwrap(forged, t, b, key.Id));
    }

    [Fact]
    public void ARotatedKeyOpensOnlyForItsHolderAndOnlyIfMadeWithTheOldKey()
    {
        var holder = DeviceKeyPair.Generate();
        var old = LibraryKey.Generate();
        var next = LibraryKey.Generate();
        var wrapped = KeyRotation.Wrap(next, old, holder.PublicKey, Lib, Mac);
        Assert.Equal(next, KeyRotation.Unwrap(wrapped, holder, old, Lib, Mac, next.Id));
        Assert.Throws<SyncException>(() => KeyRotation.Unwrap(wrapped, holder, LibraryKey.Generate(), Lib, Mac, next.Id));
        Assert.Throws<SyncException>(() => KeyRotation.Unwrap(wrapped, DeviceKeyPair.Generate(), old, Lib, Mac, next.Id));
        Assert.Throws<SyncException>(() => KeyRotation.Unwrap(wrapped, holder, old, Lib, new DeviceId("other"), next.Id));
        Assert.Throws<SyncException>(() => KeyRotation.Unwrap(wrapped, holder, old, Lib, Mac, LibraryKey.Generate().Id));
    }

    [Fact]
    public void KeysRoundTripAndNeverPrintTheirSecrets()
    {
        var pair = DeviceKeyPair.Generate();
        Assert.Equal(pair.PublicKey, DeviceKeyPair.FromEncoded(pair.EncodedPrivateKey)!.PublicKey);
        Assert.DoesNotContain(pair.EncodedPrivateKey, pair.ToString());
        var key = LibraryKey.Generate();
        Assert.Equal(32, key.Id.Length);
        Assert.Matches("^[0-9a-f]{32}$", key.Id);
        Assert.Equal(key, LibraryKey.FromEncoded(key.Encoded));
        Assert.DoesNotContain(key.Encoded, key.ToString());
        Assert.Null(LibraryKey.FromEncoded("short"));
    }

    [Fact]
    public void SealedSignInsOpenOnlyWithTheKeyProviderAndRevision()
    {
        var key = LibraryKey.Generate();
        var sealedText = SignInSealing.Seal("cookie"u8, ProviderId.YouTubeMusic, 3, key);
        Assert.Equal("cookie"u8.ToArray(), SignInSealing.Open(sealedText, ProviderId.YouTubeMusic, 3, key));
        Assert.Throws<SyncException>(() => SignInSealing.Open(sealedText, ProviderId.YouTubeMusic, 2, key));
        Assert.Throws<SyncException>(() => SignInSealing.Open(sealedText, ProviderId.Spotify, 3, key));
        Assert.Throws<SyncException>(() => SignInSealing.Open(sealedText, ProviderId.YouTubeMusic, 3, LibraryKey.Generate()));
        Assert.Throws<SyncException>(() => SignInSealing.Open("@@@", ProviderId.YouTubeMusic, 3, key));
        var legacy = SignInSealing.SealLegacy("old"u8, ProviderId.Spotify, key);
        Assert.Throws<SyncException>(() => SignInSealing.Open(legacy, ProviderId.Spotify, 0, key));
        Assert.Equal("old"u8.ToArray(), SignInSealing.OpenLegacy(legacy, ProviderId.Spotify, key));
    }

    // MARK: Convex values

    [Fact]
    public void Int64UsesLittleEndianBase64()
    {
        Assert.Equal("{\"$integer\":\"BwAAAAAAAAA=\"}", ConvexValue.Int64(7).JsonString());
        Assert.Equal(ConvexValue.Int64(-2), ConvexValue.Parse(ConvexValue.Int64(-2).JsonString()));
        Assert.Equal(long.MaxValue, ConvexValue.Parse(ConvexValue.Int64(long.MaxValue).JsonString()).Int64Value);
    }

    [Fact]
    public void SpecialFloatsUseDollarFloat()
    {
        foreach (var d in new[] { double.NaN, double.PositiveInfinity, double.NegativeInfinity, -0.0 })
        {
            var text = ConvexValue.Float64(d).JsonString();
            Assert.StartsWith("{\"$float\":", text);
            var back = ConvexValue.Parse(text).DoubleValue!.Value;
            Assert.Equal(BitConverter.DoubleToInt64Bits(d), BitConverter.DoubleToInt64Bits(back));
        }
        Assert.Equal("2.5", ConvexValue.Float64(2.5).JsonString());
        Assert.Equal("3", ConvexValue.Float64(3).JsonString());
    }

    [Fact]
    public void BytesStringsNestingAndSortedKeys()
    {
        var v = ConvexValue.Object(("b", ConvexValue.Bytes([1, 2, 3])), ("a", ConvexValue.Array(ConvexValue.String("x\n\"\u0001é"), ConvexValue.Null, ConvexValue.Bool(true))));
        Assert.Equal("{\"a\":[\"x\\n\\\"\\u0001é\",null,true],\"b\":{\"$bytes\":\"AQID\"}}", v.JsonString());
        Assert.Equal(v, ConvexValue.Parse(v.JsonString()));
        Assert.Throws<ConvexValueException>(() => ConvexValue.Parse("{\"$set\":\"x\"}"));
    }

    [Fact]
    public void WireShapesMatchTheSwiftClient()
    {
        // Optional fields left out, release fields required as null, commands discriminated by kind.
        var register = ConvexValue.Encode(new RegisterArgs("t", new DeviceInfo("PC", DevicePlatform.Mac, "m", "1"), "pk", null, 5));
        Assert.Null(register["keyId"]);
        Assert.Equal(ConvexValue.String("mac"), register["device"]!["platform"]);
        var release = ConvexValue.Encode(new ReleaseKeyArgs("t", "k", null, null, 3));
        Assert.Equal(ConvexValue.Null, release["accountKeyId"]);
        Assert.Equal(ConvexValue.Null, release["rekeyKeyId"]);
        var reseal = ConvexValue.Encode(new RotateReseal(ProviderId.YouTubeMusic, 2, null));
        Assert.Equal(ConvexValue.String("youtubeMusic"), reseal["provider"]);
        Assert.Equal(ConvexValue.Null, reseal["sealed"]);
        var seek = ConvexValue.Encode(WireCommand.Plain(SyncCommand.Seek(1500)));
        Assert.Equal("{\"kind\":\"seek\",\"positionMs\":1500}", seek.JsonString());
        // A takeover never goes in the clear: only its anchor and the sealed queue.
        Assert.Throws<InvalidOperationException>(() => WireCommand.Plain(SyncCommand.TakeOver(new HandoffState { Anchor = new PlaybackAnchor() })));
        var sealedQueue = new SealedContent(1, new string('a', 32), "c2VhbGVk");
        var takeOver = ConvexValue.Encode(new WireCommand(SyncCommandKind.TakeOver, Anchor: new PlaybackAnchor { PositionMs = 5 }, Content: sealedQueue));
        Assert.Equal(ConvexValue.String("takeOver"), takeOver["kind"]);
        Assert.Null(takeOver["state"]);
        Assert.Equal(1.0, takeOver["content"]!["v"]!.DoubleValue);
        // Publish: content left out (keep), null (drop) or both blobs (replace).
        var anchor = new PlaybackAnchor { PositionMs = 1 };
        Assert.Null(ConvexValue.Encode(new PublishArgs("t", anchor, new PublishContent.Keep()))["content"]);
        Assert.Equal(ConvexValue.Null, ConvexValue.Encode(new PublishArgs("t", anchor, new PublishContent.Drop()))["content"]);
        var replaced = ConvexValue.Encode(new PublishArgs("t", anchor, new PublishContent.Replace(sealedQueue, sealedQueue)));
        Assert.Equal(ConvexValue.String("c2VhbGVk"), replaced["content"]!["queue"]!["sealed"]);
        // A result: the reason as a code, never a message in the clear.
        var result = ConvexValue.Encode(new WireResult(false, CommandFailure.PlaybackFailed));
        Assert.Equal("{\"ok\":false,\"reason\":\"playbackFailed\"}", result.JsonString());
        var list = ConvexValue.Parse("""
            {"selfId":"d1","libraryId":"l","keyId":null,"rotationNeeded":false,"keyRevision":4,"grant":null,"rekey":null,
             "devices":[{"id":"d1","name":"Mac","platform":"mac","model":"m","appVersion":"1","createdAt":1,"lastSeenAt":2,"keyState":"requested","publicKey":"pk",
                         "exchange":{"phase":"answered","commitment":"c","at":3,"holder":"d2","holderKey":"hk","holderNonce":"hn"}}]}
            """).Decode<DeviceListResult>();
        Assert.Equal(4, list.KeyRevision);
        Assert.Equal(KeyStateKind.Requested, list.Devices[0].KeyState);
        Assert.Equal(new KeyExchangeRow(ExchangePhase.Answered, "c", new DeviceId("d2"), "hk", "hn"), list.Devices[0].Exchange);
        // A Windows device registers as windows (the backend and the Swift apps take it), and a platform this build doesn't
        // know reads as Unknown instead of failing the whole list.
        Assert.Equal(ConvexValue.String("windows"), ConvexValue.Encode(SyncService.WireDeviceInfo(new DeviceInfo("PC", DevicePlatform.Windows, "m", "1")))["platform"]);
        var future = ConvexValue.Parse("""{"id":"d9","name":"Tablet","platform":"fuchsia","model":"m","appVersion":"1"}""").Decode<SyncDevice>();
        Assert.Equal(DevicePlatform.Unknown, future.Platform);
        Assert.Equal(DevicePlatform.Android, ConvexValue.Parse("\"android\"").Decode<DevicePlatform>());
    }

    [Fact]
    public void QueueEntriesTravelAsSwiftWritesThem()
    {
        var entry = new QueueEntry(new Track { ProviderID = "abc", Provider = ProviderId.YouTubeMusic, Title = "Song" }, uid: Guid.Parse("01234567-89ab-cdef-0123-456789abcdef"));
        var v = ConvexValue.Encode(entry);
        Assert.Equal(ConvexValue.String("01234567-89AB-CDEF-0123-456789ABCDEF"), v["uid"]);   // uppercase, as Swift's UUID
        Assert.Null(v["context"]);
        Assert.Equal(entry.Uid, v.Decode<QueueEntry>().Uid);
    }

    // MARK: Clock, anchors, queue windows

    [Fact]
    public void TheClockUsesTheFastestRoundTripAndOldSamplesFallOut()
    {
        var clock = new ServerClock();
        var t0 = DateTimeOffset.FromUnixTimeMilliseconds(1_000_000);
        clock.Record(1_000_500, t0, t0.AddMilliseconds(400));   // offset 300, rtt 400
        clock.Record(1_001_050, t0.AddMilliseconds(1000), t0.AddMilliseconds(1100));   // offset 0, rtt 100
        Assert.Equal(0, clock.OffsetMs, 3);
        for (var i = 0; i < ServerClock.MaxSamples; i++) clock.Record(1_010_000 + 900 + i * 1000, t0.AddMilliseconds(10_000 + i * 1000), t0.AddMilliseconds(10_200 + i * 1000));
        Assert.Equal(800, clock.OffsetMs, 3);
        Assert.Equal(ServerClock.MaxSamples, clock.Samples.Count);
    }

    [Fact]
    public void ExtrapolationFollowsTheAnchor()
    {
        var anchor = new PlaybackAnchor { PositionMs = 10_000, PositionAt = 1_000_000, IsPlaying = true, Rate = 1, DurationMs = 15_000, Volume = 1 };
        Assert.Equal(12, anchor.Position(1_002_000), 3);
        Assert.Equal(15, anchor.Position(1_100_000), 3);   // clamped to the length
        Assert.Equal(10, (anchor with { IsPlaying = false }).Position(1_100_000), 3);
    }

    [Fact]
    public void QueueWindowKeeps20BeforeAnd100After()
    {
        var queue = Enumerable.Range(0, 200).Select(i => new QueueEntry(new Track { ProviderID = $"t{i}", Provider = ProviderId.Spotify, Title = $"{i}" })).ToList();
        var window = QueueWindow.Around(queue, 50)!;
        Assert.Equal(121, window.Entries.Count);
        Assert.Equal(20, window.Index);
        Assert.Equal("50", window.Current.Track.Title);
        Assert.Null(QueueWindow.Around(queue, 200));
    }

    // MARK: Stores

    [Fact]
    public void TheFileStoreIsOwnerOnlyAndKeepsTheKeyPairAndRedactsCredentials()
    {
        var dir = Path.Combine(Path.GetTempPath(), "openmusic-store-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new SyncCredentialStore(new FileSecretStore(dir));
            var credentials = new SyncCredentials
            {
                DeviceId = new DeviceId("d"), LibraryId = new LibraryId("l"), Token = SyncCredentials.NewDeviceToken(), DeploymentUrl = new Uri("https://x.convex.cloud"),
                DeviceKey = DeviceKeyPair.Generate(), UserId = "u", LibraryKey = LibraryKey.Generate(),
            };
            Assert.True(store.Persist(credentials));
            Assert.Equal(credentials, new SyncCredentialStore(new FileSecretStore(dir)).Load());
            if (!OperatingSystem.IsWindows())
            {
                Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute, File.GetUnixFileMode(dir));
                Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite, File.GetUnixFileMode(Path.Combine(dir, "sync.credentials")));
            }
            Assert.DoesNotContain(credentials.Token, credentials.ToString());
            Assert.True(store.PersistState("keys.v1", "x"u8.ToArray()));
            Assert.True(File.Exists(Path.Combine(dir, "sync.credentials.state.keys.v1")));
            // Credentials from before accounts (no key pair) are dropped; state is kept.
            File.WriteAllText(Path.Combine(dir, "sync.credentials"), "{\"deviceID\":\"d\",\"token\":\"t\"}");
            Assert.Null(store.Load());
            Assert.Equal("x"u8.ToArray(), store.State("keys.v1"));
        }
        finally { Directory.Delete(dir, true); }
    }
}
