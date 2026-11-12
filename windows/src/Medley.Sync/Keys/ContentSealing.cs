using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Medley.Core;

namespace Medley.Sync.Keys;

// Byte-compatible port of Sources/MedleySync/Keys/ContentSealing.swift: what someone listens to and searches for reaches
// the server only sealed with the vault key (docs/sync-design.md, "What the server can see"). Vectors made by the Swift
// code (Vectors/swift-content-vectors.json) are checked by CrossLanguageVectorTests.

/// <summary>One sealed field as it travels and is stored: <c>{ v: 1, keyId, sealed }</c>, <c>sealed</c> base64 of the
/// AES-GCM nonce ‖ ciphertext ‖ tag under the content key of its kind.</summary>
public sealed record SealedContent(
    [property: JsonPropertyName("v")] int V,
    [property: JsonPropertyName("keyId")] string KeyId,
    [property: JsonPropertyName("sealed")] string Sealed);

/// <summary>What a sealed field holds. Each kind has its own content key and its own place in the authenticated data.</summary>
public enum ContentKind
{
    /// <summary>The current track, its index in the window and the window's length (<see cref="PlaybackContent"/>).</summary>
    Playback,
    /// <summary>The queue window.</summary>
    Queue,
    /// <summary>A takeover's queue window; the context is the target device.</summary>
    Command,
    /// <summary>A failed command's message; the context is the command id.</summary>
    Result,
    /// <summary>A setting's JSON text; the context is the setting key.</summary>
    Setting,
}

public sealed class ContentSealingException(string message) : Exception(message);

/// <summary>
/// End-to-end sealing of playback, queues, takeovers, results and settings.
/// <list type="bullet">
/// <item>Content key: HKDF-SHA256(ikm: vault key, salt: none, info: <c>medley.content.v1.&lt;kind&gt;</c>, 32 bytes).</item>
/// <item>Seal: AES-256-GCM, a fresh random 12-byte nonce per seal, CryptoKit's combined format, base64.</item>
/// <item>Authenticated data: <c>medley.content.v1</c>, then five fields, each a 4-byte big-endian length and its UTF-8
/// bytes: kind, library id, writing device id, vault key fingerprint, context (setting key, target device, command id;
/// empty for playback and queues).</item>
/// </list>
/// </summary>
public static class ContentSealing
{
    private const string Domain = "medley.content.v1";

    public static string Name(ContentKind kind) => kind switch
    {
        ContentKind.Playback => "playback",
        ContentKind.Queue => "queue",
        ContentKind.Command => "command",
        ContentKind.Result => "result",
        ContentKind.Setting => "setting",
        _ => throw new ArgumentOutOfRangeException(nameof(kind)),
    };

    internal static byte[] ContentKey(LibraryKey key, ContentKind kind) =>
        HKDF.DeriveKey(HashAlgorithmName.SHA256, key.CopyBytes(), 32, salt: [], info: Encoding.UTF8.GetBytes($"{Domain}.{Name(kind)}"));

    internal static byte[] AssociatedData(ContentKind kind, LibraryId library, DeviceId writer, string keyId, string context)
    {
        var data = new List<byte>(Encoding.UTF8.GetBytes(Domain));
        Span<byte> length = stackalloc byte[4];
        foreach (var field in new[] { Name(kind), library.Value, writer.Value, keyId, context })
        {
            var bytes = Encoding.UTF8.GetBytes(field);
            BinaryPrimitives.WriteUInt32BigEndian(length, (uint)bytes.Length);
            data.AddRange(length.ToArray());
            data.AddRange(bytes);
        }
        return data.ToArray();
    }

    /// <summary>Seals <paramref name="plaintext"/> written by <paramref name="writer"/> in <paramref name="library"/>.
    /// <paramref name="nonce"/> is for the fixed test vectors only; never reuse one under a key.</summary>
    public static SealedContent Seal(ReadOnlySpan<byte> plaintext, ContentKind kind, LibraryId library, DeviceId writer, string context,
                                     LibraryKey key, byte[]? nonce = null)
    {
        var aad = AssociatedData(kind, library, writer, key.Id, context);
        var combined = AesGcmCombined.Seal(plaintext, ContentKey(key, kind), aad, nonce);
        return new SealedContent(1, key.Id, Convert.ToBase64String(combined));
    }

    /// <summary>Opens a blob <paramref name="writer"/> wrote. Null when it isn't sealed under <paramref name="key"/> (a retired
    /// key, or one this device doesn't have yet): readers skip those. Throws when it is under the key but doesn't open.</summary>
    public static byte[]? Open(SealedContent sealedContent, ContentKind kind, LibraryId library, DeviceId writer, string context, LibraryKey key)
    {
        if (sealedContent.V != 1 || sealedContent.KeyId != key.Id) return null;
        byte[] data;
        try { data = Convert.FromBase64String(sealedContent.Sealed); }
        catch (FormatException) { throw new ContentSealingException("malformed"); }
        try { return AesGcmCombined.Open(data, ContentKey(key, kind), AssociatedData(kind, library, writer, key.Id, context)); }
        catch (CryptographicException) { throw new ContentSealingException("doesn't open"); }
    }

    /// <summary>Seals a value as JSON (the wire's JSON, which the Swift apps decode).</summary>
    public static SealedContent SealJson<T>(T value, ContentKind kind, LibraryId library, DeviceId writer, string context, LibraryKey key) =>
        Seal(JsonSerializer.SerializeToUtf8Bytes(value, Wire.Options), kind, library, writer, context, key);

    /// <summary>Opens and decodes a JSON value; null when the blob isn't under <paramref name="key"/> or doesn't open or decode.</summary>
    public static T? TryOpenJson<T>(SealedContent sealedContent, ContentKind kind, LibraryId library, DeviceId writer, string context, LibraryKey key)
        where T : class
    {
        try
        {
            return Open(sealedContent, kind, library, writer, context, key) is { } data ? JsonSerializer.Deserialize<T>(data, Wire.Options) : null;
        }
        catch (Exception e) when (e is ContentSealingException or JsonException) { return null; }
    }
}

/// <summary>What the <c>playback</c> kind holds: the device's current track and where it is in its window.</summary>
public sealed record PlaybackContent(
    [property: JsonPropertyName("track")] Track Track,
    [property: JsonPropertyName("index")] int Index,
    [property: JsonPropertyName("queueLength")] int QueueLength);

/// <summary>What the <c>result</c> kind holds: a failed command's message, which may name a song.</summary>
public sealed record ResultContent([property: JsonPropertyName("message")] string Message);
