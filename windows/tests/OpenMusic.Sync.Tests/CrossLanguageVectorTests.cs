using System.Text;
using System.Text.Json;
using OpenMusic.Core;
using OpenMusic.Sync.Keys;

namespace OpenMusic.Sync.Tests;

/// <summary>
/// Vectors made by the Swift implementation (CryptoKit), checked in as Vectors/swift-vectors.json by
/// windows/scripts/swift-vectors.sh. The C# code must derive exactly the same values and open everything Swift sealed.
/// The other direction (Swift opening what C# sealed) is <see cref="WriteCSharpVectors"/> plus the same script.
/// </summary>
public class CrossLanguageVectorTests
{
    private static readonly JsonElement V = Load();

    private static JsonElement Load()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Vectors", "swift-vectors.json");
        return JsonDocument.Parse(File.ReadAllText(path)).RootElement.Clone();
    }

    private static string S(string key) => V.GetProperty(key).GetString()!;
    private static byte[] D(string key) => Convert.FromBase64String(S(key));

    private static DeviceKeyPair A => new(D("privateA"));
    private static DeviceKeyPair B => new(D("privateB"));
    private static LibraryKey K1 => LibraryKey.FromEncoded(S("k1"))!;
    private static LibraryKey K2 => LibraryKey.FromEncoded(S("k2"))!;
    private static LibraryId Library => new(S("libraryId"));
    private static DeviceId Holder => new(S("holderId"));
    private static DeviceId Requester => new(S("requesterId"));

    private static KeyExchange.Transcript Transcript(byte[]? holderNonce = null) =>
        new(Library, Requester, B.PublicKey, D("requesterNonce"), Holder, A.PublicKey, holderNonce ?? D("holderNonce"));

    [Fact]
    public void PublicKeysMatchCryptoKit()
    {
        Assert.Equal(S("publicA"), A.PublicKey);
        Assert.Equal(S("publicB"), B.PublicKey);
    }

    [Fact]
    public void AnUnclampedCryptoKitPrivateKeyGivesTheSamePublicKeyAndSharedSecret()
    {
        var native = new DeviceKeyPair(D("nativePrivate"));
        Assert.Equal(S("nativePublic"), native.PublicKey);
        Assert.Equal(S("nativeShared"), Convert.ToBase64String(X25519.Implementation.Agree(D("nativePrivate"), D("nativePeerPublic"))!));
    }

    [Fact]
    public void VaultKeyFingerprintsMatch()
    {
        Assert.Equal(S("k1Id"), K1.Id);
        Assert.Equal(S("k2Id"), K2.Id);
        Assert.Equal(S("k1"), K1.Encoded);
    }

    [Fact]
    public void CommitmentAnswerNonceDigestAndCodeMatch()
    {
        Assert.Equal(S("commitment"), KeyExchange.Commitment(B.PublicKey, D("requesterNonce")));
        var nonce = KeyExchange.AnswerNonce(A, Holder, Library, Requester, B.PublicKey, S("commitment"));
        Assert.Equal(S("holderNonce"), Convert.ToBase64String(nonce!));
        var t = Transcript();
        Assert.Equal(S("digest"), Convert.ToBase64String(t.Digest));
        Assert.Equal(S("code"), t.Code);
    }

    [Fact]
    public void SixtyFourCodesMatch()
    {
        var codes = V.GetProperty("codes").EnumerateArray().ToList();
        Assert.Equal(64, codes.Count);
        foreach (var c in codes)
        {
            var t = Transcript(Convert.FromBase64String(c.GetProperty("holderNonce").GetString()!));
            Assert.Equal(c.GetProperty("digest").GetString(), Convert.ToBase64String(t.Digest));
            Assert.Equal(c.GetProperty("code").GetString(), t.Code);
        }
    }

    [Fact]
    public void TheSwiftGrantOpensForTheRequesterOnly()
    {
        var key = KeyExchange.Unwrap(S("grant"), Transcript(), B, K1.Id);
        Assert.Equal(K1, key);
        // Another transcript (another holder nonce) doesn't open it.
        var other = Transcript(KeyExchange.Nonce());
        Assert.Throws<SyncException>(() => KeyExchange.Unwrap(S("grant"), other, B, K1.Id));
    }

    [Fact]
    public void TheSwiftRotationOpensOnlyWithTheOldKey()
    {
        Assert.Equal(K2, KeyRotation.Unwrap(S("rotation"), A, K1, Library, Holder, K2.Id));
        Assert.Throws<SyncException>(() => KeyRotation.Unwrap(S("rotation"), A, K2, Library, Holder, K2.Id));
        Assert.Throws<SyncException>(() => KeyRotation.Unwrap(S("rotation"), B, K1, Library, Holder, K2.Id));
    }

    [Fact]
    public void SwiftSealedSignInsOpenOnlyForTheirProviderAndRevision()
    {
        var revision = V.GetProperty("sealedRevision").GetInt32();
        Assert.Equal(D("plaintext"), SignInSealing.Open(S("sealed"), ProviderId.YouTubeMusic, revision, K1));
        Assert.Throws<SyncException>(() => SignInSealing.Open(S("sealed"), ProviderId.YouTubeMusic, revision + 1, K1));
        Assert.Throws<SyncException>(() => SignInSealing.Open(S("sealed"), ProviderId.Spotify, revision, K1));
        Assert.Equal("refresh-token-vector"u8.ToArray(), SignInSealing.Open(S("sealedSpotify"), ProviderId.Spotify, 1, K2));
        Assert.Equal("legacy-vector"u8.ToArray(), SignInSealing.OpenLegacy(S("legacy"), ProviderId.Spotify, K1));
    }

    [Fact]
    public void DeviceTokensHaveTheSameShape()
    {
        Assert.Equal(S("deviceToken").Length, SyncCredentials.NewDeviceToken().Length);
    }

    /// <summary>
    /// Writes what C# derives and seals from the same inputs to OPENMUSIC_CSHARP_VECTORS_OUT (when set), for the Swift side to
    /// open (windows/scripts/swift-vectors.sh &lt;checkout&gt; &lt;that file&gt;).
    /// </summary>
    [Fact]
    public void WriteCSharpVectors()
    {
        var t = Transcript();
        var vectors = new Dictionary<string, object>
        {
            ["privateA"] = S("privateA"), ["privateB"] = S("privateB"), ["publicA"] = A.PublicKey, ["publicB"] = B.PublicKey,
            ["k1"] = K1.Encoded, ["k1Id"] = K1.Id, ["k2"] = K2.Encoded,
            ["libraryId"] = Library.Value, ["holderId"] = Holder.Value, ["requesterId"] = Requester.Value,
            ["requesterNonce"] = S("requesterNonce"), ["commitment"] = KeyExchange.Commitment(B.PublicKey, D("requesterNonce"))!,
            ["holderNonce"] = Convert.ToBase64String(KeyExchange.AnswerNonce(A, Holder, Library, Requester, B.PublicKey, S("commitment"))!),
            ["code"] = t.Code,
            ["grant"] = KeyExchange.Wrap(K1, t, A),
            ["rotation"] = KeyRotation.Wrap(K2, K1, A.PublicKey, Library, Holder),
            ["plaintext"] = S("plaintext"),
            ["sealed"] = SignInSealing.Seal(D("plaintext"), ProviderId.YouTubeMusic, 7, K1),
            ["sealedRevision"] = 7,
            ["legacy"] = SignInSealing.SealLegacy("legacy-vector"u8, ProviderId.Spotify, K1),
        };
        // Round trip in C# first.
        Assert.Equal(K1, KeyExchange.Unwrap((string)vectors["grant"], t, B, K1.Id));
        Assert.Equal(K2, KeyRotation.Unwrap((string)vectors["rotation"], A, K1, Library, Holder, K2.Id));
        if (LaunchEnvironment.Get("OPENMUSIC_CSHARP_VECTORS_OUT") is { Length: > 0 } path)
            File.WriteAllText(path, JsonSerializer.Serialize(vectors, new JsonSerializerOptions { WriteIndented = true }), Encoding.UTF8);
    }
}
