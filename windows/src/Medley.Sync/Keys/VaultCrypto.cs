using System.Buffers.Binary;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Medley.Core;
using Medley.Sync.Convex;

namespace Medley.Sync.Keys;

// Byte-compatible ports of Sources/MedleySync/Keys/VaultKey.swift (CryptoKit). Cross-language vectors made by the Swift
// code live in Medley.Sync.Tests/Vectors and are checked by CrossLanguageVectorTests.

/// <summary>
/// X25519 (RFC 7748). The default is BouncyCastle's managed implementation, which runs the same on Windows (x64, ARM64)
/// and Linux, so the tests on Linux exercise the code the app ships. Swap <see cref="Implementation"/> for another
/// (Windows CNG, libsodium) behind the same contract.
/// </summary>
public interface IX25519
{
    /// <summary>The public key of a 32-byte private key (the scalar is clamped as RFC 7748 decodes it; the stored bytes aren't).</summary>
    byte[] PublicKey(ReadOnlySpan<byte> privateKey);
    /// <summary>The shared secret, or null when it is all zeros (a low-order peer key), which CryptoKit refuses too.</summary>
    byte[]? Agree(ReadOnlySpan<byte> privateKey, ReadOnlySpan<byte> peerPublicKey);
}

public static class X25519
{
    public static IX25519 Implementation { get; set; } = new BouncyCastleX25519();
}

internal sealed class BouncyCastleX25519 : IX25519
{
    public byte[] PublicKey(ReadOnlySpan<byte> privateKey)
    {
        if (privateKey.Length != 32) throw new ArgumentException("X25519 private keys are 32 bytes");
        var pub = new byte[32];
        Org.BouncyCastle.Math.EC.Rfc7748.X25519.ScalarMultBase(privateKey.ToArray(), 0, pub, 0);
        return pub;
    }

    public byte[]? Agree(ReadOnlySpan<byte> privateKey, ReadOnlySpan<byte> peerPublicKey)
    {
        if (privateKey.Length != 32 || peerPublicKey.Length != 32) return null;
        var shared = new byte[32];
        return Org.BouncyCastle.Math.EC.Rfc7748.X25519.CalculateAgreement(privateKey.ToArray(), 0, peerPublicKey.ToArray(), 0, shared, 0) ? shared : null;
    }
}

/// <summary>AES-256-GCM in CryptoKit's combined format: 12-byte nonce ‖ ciphertext ‖ 16-byte tag.</summary>
public static class AesGcmCombined
{
    public static byte[] Seal(ReadOnlySpan<byte> plaintext, ReadOnlySpan<byte> key, ReadOnlySpan<byte> associatedData = default, byte[]? nonce = null)
    {
        nonce ??= RandomNumberGenerator.GetBytes(12);
        var output = new byte[12 + plaintext.Length + 16];
        nonce.CopyTo(output, 0);
        using var aes = new AesGcm(key, 16);
        aes.Encrypt(nonce, plaintext, output.AsSpan(12, plaintext.Length), output.AsSpan(12 + plaintext.Length, 16), associatedData);
        return output;
    }

    /// <summary>Throws <see cref="CryptographicException"/> when it doesn't open.</summary>
    public static byte[] Open(ReadOnlySpan<byte> combined, ReadOnlySpan<byte> key, ReadOnlySpan<byte> associatedData = default)
    {
        if (combined.Length < 28) throw new CryptographicException("sealed box too short");
        var plaintext = new byte[combined.Length - 28];
        using var aes = new AesGcm(key, 16);
        aes.Decrypt(combined[..12], combined.Slice(12, plaintext.Length), combined[^16..], plaintext, associatedData);
        return plaintext;
    }
}

/// <summary>
/// The account's vault key: 32 random bytes. It lives in each device's credential store and travels only wrapped to
/// another device's key; the server sees only <see cref="Id"/>, its fingerprint.
/// </summary>
public sealed class LibraryKey : IEquatable<LibraryKey>
{
    private readonly byte[] _key;
    /// <summary>First 16 bytes of SHA-256("medley.library-key.v1" ‖ key), as 32 lowercase hex characters.</summary>
    public string Id { get; }

    public LibraryKey(ReadOnlySpan<byte> key)
    {
        if (key.Length != 32) throw new ArgumentException("vault keys are 32 bytes");
        _key = key.ToArray();
        var input = new byte[21 + 32];
        Encoding.UTF8.GetBytes("medley.library-key.v1").CopyTo(input, 0);
        _key.CopyTo(input, 21);
        Id = Convert.ToHexStringLower(SHA256.HashData(input).AsSpan(0, 16));
    }

    public static LibraryKey Generate() => new(RandomNumberGenerator.GetBytes(32));

    internal ReadOnlySpan<byte> Bytes => _key;
    internal byte[] CopyBytes() => _key.ToArray();

    /// <summary>base64url of the 32 key bytes, as the credentials store it.</summary>
    public string Encoded => Base64Url.Encode(_key);

    public static LibraryKey? FromEncoded(string text) => Base64Url.TryDecode(text) is { Length: 32 } data ? new LibraryKey(data) : null;

    public bool Equals(LibraryKey? other) => other is not null && other.Id == Id;
    public override bool Equals(object? obj) => obj is LibraryKey k && Equals(k);
    public override int GetHashCode() => Id.GetHashCode(StringComparison.Ordinal);
    public static bool operator ==(LibraryKey? a, LibraryKey? b) => a is null ? b is null : a.Equals(b);
    public static bool operator !=(LibraryKey? a, LibraryKey? b) => !(a == b);
    public override string ToString() => $"LibraryKey(id: {Id}, key: <redacted>)";
}

/// <summary>
/// AES-GCM sealing of a provider's sign-in under the vault key. The provider and the vault revision the write gets are
/// bound in as authenticated data (<c>medley.vault.v2:&lt;provider&gt;:&lt;revision&gt;</c>), so a blob can't be replayed as
/// another provider's, nor at another revision.
/// </summary>
public static class SignInSealing
{
    internal static byte[] AssociatedData(ProviderId provider, int revision) =>
        Encoding.UTF8.GetBytes($"medley.vault.v2:{provider.RawValue()}:{revision.ToString(CultureInfo.InvariantCulture)}");

    internal static byte[] LegacyAssociatedData(ProviderId provider) => Encoding.UTF8.GetBytes($"medley.vault.v1:{provider.RawValue()}");

    /// <summary>Base64 of nonce ‖ ciphertext ‖ tag. <paramref name="revision"/> is the revision the row will have once written.</summary>
    public static string Seal(ReadOnlySpan<byte> plaintext, ProviderId provider, int revision, LibraryKey key) =>
        Convert.ToBase64String(AesGcmCombined.Seal(plaintext, key.Bytes, AssociatedData(provider, revision)));

    /// <summary>Opens a blob read from the vault row at <paramref name="revision"/>. Fails for a blob sealed for any other revision.</summary>
    public static byte[] Open(string sealedText, ProviderId provider, int revision, LibraryKey key) =>
        OpenWith(sealedText, key, AssociatedData(provider, revision));

    /// <summary>Opens a legacy (v1) blob. Only for an entry at revision 0.</summary>
    public static byte[] OpenLegacy(string sealedText, ProviderId provider, LibraryKey key) =>
        OpenWith(sealedText, key, LegacyAssociatedData(provider));

    internal static string SealLegacy(ReadOnlySpan<byte> plaintext, ProviderId provider, LibraryKey key) =>
        Convert.ToBase64String(AesGcmCombined.Seal(plaintext, key.Bytes, LegacyAssociatedData(provider)));

    private static byte[] OpenWith(string sealedText, LibraryKey key, byte[] aad)
    {
        var data = Base64Url.TryDecodeStandard(sealedText) ?? throw SyncException.SignInTransferFailed("the sealed sign-in is malformed");
        try { return AesGcmCombined.Open(data, key.Bytes, aad); }
        catch (CryptographicException) { throw SyncException.SignInTransferFailed("the library key doesn't open this sign-in"); }
    }
}

/// <summary>This device's X25519 key pair. The server stores only the public half.</summary>
public sealed class DeviceKeyPair
{
    private readonly byte[] _private;

    public DeviceKeyPair(ReadOnlySpan<byte> privateKey)
    {
        if (privateKey.Length != 32) throw new ArgumentException("X25519 private keys are 32 bytes");
        _private = privateKey.ToArray();
        PublicKeyBytes = X25519.Implementation.PublicKey(_private);
        PublicKey = Convert.ToBase64String(PublicKeyBytes);
    }

    public static DeviceKeyPair Generate() => new(RandomNumberGenerator.GetBytes(32));

    internal ReadOnlySpan<byte> PrivateKey => _private;
    public byte[] PublicKeyBytes { get; }
    /// <summary>base64 of the 32-byte public key, as the server stores it.</summary>
    public string PublicKey { get; }

    /// <summary>base64 of the private key, for the credential store only.</summary>
    internal string EncodedPrivateKey => Convert.ToBase64String(_private);
    internal static DeviceKeyPair? FromEncoded(string text) => Base64Url.TryDecodeStandard(text) is { Length: 32 } d ? new DeviceKeyPair(d) : null;

    internal byte[]? Agree(ReadOnlySpan<byte> peer) => X25519.Implementation.Agree(_private, peer);

    public override string ToString() => $"DeviceKeyPair(public: {PublicKey}, private: <redacted>)";
}

/// <summary>
/// The verification exchange that moves the vault key to a new device (docs/accounts-design.md, "Approving a device").
/// The sync server relays it and is not trusted: nothing here relies on what it says.
/// </summary>
public static class KeyExchange
{
    internal static readonly byte[] CommitDomain = Encoding.UTF8.GetBytes("medley.key-exchange.v1.commit");
    internal static readonly byte[] TranscriptDomain = Encoding.UTF8.GetBytes("medley.key-exchange.v1.transcript");
    internal static readonly byte[] CodeDomain = Encoding.UTF8.GetBytes("medley.key-exchange.v1.code");
    internal static readonly byte[] AnswerNonceDomain = Encoding.UTF8.GetBytes("medley.key-exchange.v2.answer-nonce");

    /// <summary>32 random bytes.</summary>
    public static byte[] Nonce() => RandomNumberGenerator.GetBytes(32);

    /// <summary>
    /// A holder's nonce for answering one request: HMAC-SHA256 under HKDF(private key, info: answer-nonce domain) over
    /// the library, the asking device's id and public key, its commitment, and the holder's own id and public key (each
    /// length-prefixed, keys and commitment as bytes). Null for a malformed key or commitment.
    /// </summary>
    public static byte[]? AnswerNonce(DeviceKeyPair holder, DeviceId holderId, LibraryId libraryId, DeviceId requester, string requesterKey, string commitment)
    {
        if (Base64Url.TryDecodeStandard(requesterKey) is not { Length: 32 } requesterBytes) return null;
        if (Base64Url.TryDecodeStandard(commitment) is not { Length: 32 } commitmentBytes) return null;
        var key = HKDF.DeriveKey(HashAlgorithmName.SHA256, holder.PrivateKey.ToArray(), 32, salt: [], info: AnswerNonceDomain);
        using var mac = IncrementalHash.CreateHMAC(HashAlgorithmName.SHA256, key);
        foreach (var field in new[] { Utf8(libraryId.Value), Utf8(requester.Value), requesterBytes, commitmentBytes, Utf8(holderId.Value), holder.PublicKeyBytes })
            AppendPrefixed(mac, field);
        return mac.GetHashAndReset();
    }

    /// <summary>base64 of SHA-256(commit domain ‖ public key ‖ nonce). Null for a malformed key or nonce.</summary>
    public static string? Commitment(string publicKey, ReadOnlySpan<byte> nonce)
    {
        if (Base64Url.TryDecodeStandard(publicKey) is not { Length: 32 } key || nonce.Length != 32) return null;
        using var h = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        h.AppendData(CommitDomain);
        h.AppendData(key);
        h.AppendData(nonce);
        return Convert.ToBase64String(h.GetHashAndReset());
    }

    /// <summary>Everything one run of the exchange agreed on, as each device recorded it itself.</summary>
    public sealed record Transcript(LibraryId LibraryId, DeviceId Requester, string RequesterKey, byte[] RequesterNonce,
                                    DeviceId Holder, string HolderKey, byte[] HolderNonce)
    {
        /// <summary>SHA-256 over the domain and every field, each length-prefixed.</summary>
        public byte[] Digest
        {
            get
            {
                using var h = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                h.AppendData(TranscriptDomain);
                foreach (var part in new[] { Utf8(LibraryId.Value), Utf8(Requester.Value), Base64Url.TryDecodeStandard(RequesterKey) ?? [],
                                              RequesterNonce, Utf8(Holder.Value), Base64Url.TryDecodeStandard(HolderKey) ?? [], HolderNonce })
                    AppendPrefixed(h, part);
                return h.GetHashAndReset();
            }
        }

        /// <summary>The six digits both devices show, as "482 913".</summary>
        public string Code
        {
            get
            {
                using var h = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                h.AppendData(CodeDomain);
                h.AppendData(Digest);
                var number = BinaryPrimitives.ReadUInt64BigEndian(h.GetHashAndReset().AsSpan(0, 8)) % 1_000_000;
                var digits = number.ToString("D6", CultureInfo.InvariantCulture);
                return $"{digits[..3]} {digits[3..]}";
            }
        }

        public bool Equals(Transcript? o) => o is not null && LibraryId == o.LibraryId && Requester == o.Requester && RequesterKey == o.RequesterKey
            && RequesterNonce.AsSpan().SequenceEqual(o.RequesterNonce) && Holder == o.Holder && HolderKey == o.HolderKey
            && HolderNonce.AsSpan().SequenceEqual(o.HolderNonce);
        public override int GetHashCode() => HashCode.Combine(LibraryId, Requester, Holder);
    }

    internal static byte[] GrantKey(DeviceKeyPair own, string peer, Transcript transcript, string keyId)
    {
        if (Base64Url.TryDecodeStandard(peer) is not { Length: 32 } peerData) throw SyncException.KeyGrantFailed("that device's key is malformed");
        var shared = own.Agree(peerData) ?? throw SyncException.KeyGrantFailed("that device's key is malformed");
        var info = Utf8($"medley.key-grant.v2|{transcript.LibraryId.Value}|{transcript.Requester.Value}|{keyId}");
        return HKDF.DeriveKey(HashAlgorithmName.SHA256, shared, 32, transcript.Digest, info);
    }

    /// <summary>The holder seals <paramref name="key"/> for the asking device in <paramref name="transcript"/>.</summary>
    public static string Wrap(LibraryKey key, Transcript transcript, DeviceKeyPair holder)
    {
        if (holder.PublicKey != transcript.HolderKey) throw SyncException.KeyGrantFailed("the exchange names another device");
        var wrapKey = GrantKey(holder, transcript.RequesterKey, transcript, key.Id);
        return Convert.ToBase64String(AesGcmCombined.Seal(key.Bytes, wrapKey));
    }

    /// <summary>The asking device opens a grant made for its transcript and checks the key inside has fingerprint <paramref name="keyId"/>.</summary>
    public static LibraryKey Unwrap(string wrapped, Transcript transcript, DeviceKeyPair requester, string keyId)
    {
        if (requester.PublicKey != transcript.RequesterKey) throw SyncException.KeyGrantFailed("the exchange names another device");
        var data = Base64Url.TryDecodeStandard(wrapped) ?? throw SyncException.KeyGrantFailed("the grant is malformed");
        byte[] plaintext;
        try
        {
            var wrapKey = GrantKey(requester, transcript.HolderKey, transcript, keyId);
            plaintext = AesGcmCombined.Open(data, wrapKey);
        }
        catch (Exception e) when (e is CryptographicException or SyncException)
        {
            throw SyncException.KeyGrantFailed("it doesn't open on this device");
        }
        if (plaintext.Length != 32) throw SyncException.KeyGrantFailed("the grant holds no key");
        var opened = new LibraryKey(plaintext);
        if (opened.Id != keyId) throw SyncException.KeyGrantFailed("the key isn't your account's");
        return opened;
    }

    internal static byte[] Utf8(string s) => Encoding.UTF8.GetBytes(s);

    internal static void AppendPrefixed(IncrementalHash h, byte[] field)
    {
        Span<byte> length = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(length, (uint)field.Length);
        h.AppendData(length);
        h.AppendData(field);
    }
}

/// <summary>
/// Moving a rotated vault key to the other holders (<c>keys:rotate</c>):
/// <c>wrapKey = HKDF-SHA256(X25519(e, holder) ‖ old key, salt: e.public ‖ holder, info: "medley.key-rotation.v1|lib|device|old|new")</c>,
/// <c>wrapped = base64(e.public ‖ AES.GCM.seal(new key, wrapKey).combined)</c>.
/// </summary>
public static class KeyRotation
{
    internal static byte[] WrapKey(byte[] shared, LibraryKey old, byte[] ephemeral, byte[] recipient, byte[] info) =>
        HKDF.DeriveKey(HashAlgorithmName.SHA256, [.. shared, .. old.CopyBytes()], 32, [.. ephemeral, .. recipient], info);

    internal static byte[] Info(LibraryId libraryId, DeviceId deviceId, string old, string @new) =>
        KeyExchange.Utf8($"medley.key-rotation.v1|{libraryId.Value}|{deviceId.Value}|{old}|{@new}");

    public static string Wrap(LibraryKey next, LibraryKey old, string recipient, LibraryId libraryId, DeviceId deviceId, byte[]? ephemeralPrivate = null)
    {
        if (Base64Url.TryDecodeStandard(recipient) is not { Length: 32 } recipientData) throw SyncException.KeyGrantFailed("that device's key is malformed");
        var ephemeral = new DeviceKeyPair(ephemeralPrivate ?? RandomNumberGenerator.GetBytes(32));
        var shared = ephemeral.Agree(recipientData) ?? throw SyncException.KeyGrantFailed("that device's key is malformed");
        var key = WrapKey(shared, old, ephemeral.PublicKeyBytes, recipientData, Info(libraryId, deviceId, old.Id, next.Id));
        return Convert.ToBase64String([.. ephemeral.PublicKeyBytes, .. AesGcmCombined.Seal(next.Bytes, key)]);
    }

    /// <summary>Opens a rotation wrapped to <paramref name="pair"/>, made with <paramref name="old"/>, and checks the new key's fingerprint.</summary>
    public static LibraryKey Unwrap(string wrapped, DeviceKeyPair pair, LibraryKey old, LibraryId libraryId, DeviceId deviceId, string keyId)
    {
        if (Base64Url.TryDecodeStandard(wrapped) is not { Length: > 32 } data) throw SyncException.KeyGrantFailed("the new key is malformed");
        var ephemeralPublic = data[..32];
        byte[] plaintext;
        try
        {
            var shared = pair.Agree(ephemeralPublic) ?? throw new CryptographicException("low-order key");
            var key = WrapKey(shared, old, ephemeralPublic, pair.PublicKeyBytes, Info(libraryId, deviceId, old.Id, keyId));
            plaintext = AesGcmCombined.Open(data.AsSpan(32), key);
        }
        catch (CryptographicException)
        {
            throw SyncException.KeyGrantFailed("the new key wasn't made with this device's key");
        }
        if (plaintext.Length != 32) throw SyncException.KeyGrantFailed("the new key is malformed");
        var opened = new LibraryKey(plaintext);
        if (opened.Id != keyId) throw SyncException.KeyGrantFailed("the new key isn't the one announced");
        return opened;
    }
}
