using System.Globalization;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.Json.Serialization.Metadata;
using Medley.Core.Sync;

namespace Medley.Core.Support;

/// <summary>
/// JSON the way the Swift apps write it (<c>JSONEncoder</c> defaults), with System.Text.Json source generation:
/// nil optionals left out, UUIDs as uppercase strings, URLs as strings, <c>Date</c> as seconds since 2001-01-01,
/// non-ASCII text unescaped and "/" written as "\/". Use <see cref="Serialize{T}"/> for anything stored or relayed.
/// </summary>
public static class MedleyJson
{
    /// <summary>Serializes <paramref name="value"/> to the text Swift's JSONEncoder would write (keys in declaration order;
    /// Swift's own key order is unspecified, so compare parsed JSON, not bytes).</summary>
    public static string Serialize<T>(T value, JsonTypeInfo<T> typeInfo)
    {
        // The generated Default context escapes non-ASCII; Swift doesn't. Use the relaxed context's metadata.
        if (!ReferenceEquals(typeInfo.Options.Encoder, Encoder))
            typeInfo = (JsonTypeInfo<T>)MedleyJsonContext.Swift.GetTypeInfo(typeof(T))!;
        return SwiftEscapes(JsonSerializer.Serialize(value, typeInfo));
    }

    public static byte[] SerializeToUtf8<T>(T value, JsonTypeInfo<T> typeInfo) => Encoding.UTF8.GetBytes(Serialize(value, typeInfo));

    public static T? Deserialize<T>(string json, JsonTypeInfo<T> typeInfo) => JsonSerializer.Deserialize(json, typeInfo);

    public static T? Deserialize<T>(ReadOnlySpan<byte> utf8, JsonTypeInfo<T> typeInfo) => JsonSerializer.Deserialize(utf8, typeInfo);

    /// <summary>A synced setting's value text (<see cref="SettingEntry.Value"/>): <c>true</c>, <c>2.5</c>,
    /// <c>["daft punk"]</c>, as Swift writes them.</summary>
    public static string EncodeSetting<T>(T value, JsonTypeInfo<T> typeInfo) => Serialize(value, typeInfo);

    /// <summary>
    /// Rewrites STJ's relaxed-escaping output into exactly what Swift's JSONEncoder writes. Inside strings: "/" is
    /// "\/"; only '"', '\\' and control characters are escaped (\b \f \n \r \t, else \u00xx in lowercase hex);
    /// everything STJ also escapes (U+2028, U+2029, DEL, surrogate pairs) is written as the character itself.
    /// Outside strings: exponents are lowercase ("1e-05", not "1E-05").
    /// </summary>
    internal static string SwiftEscapes(string json)
    {
        var sb = new StringBuilder(json.Length + 8);
        var inString = false;
        for (var i = 0; i < json.Length; i++)
        {
            var c = json[i];
            if (!inString)
            {
                if (c == '"') inString = true;
                sb.Append(c == 'E' ? 'e' : c);
                continue;
            }
            switch (c)
            {
                case '"':
                    inString = false;
                    sb.Append(c);
                    break;
                case '/':
                    sb.Append("\\/");
                    break;
                case '\\' when i + 1 < json.Length && json[i + 1] == 'u' && i + 5 < json.Length && TryHex(json, i + 2, out var code):
                    if (char.IsHighSurrogate((char)code) && i + 11 < json.Length && json[i + 6] == '\\' && json[i + 7] == 'u'
                        && TryHex(json, i + 8, out var low) && char.IsLowSurrogate((char)low))
                    {
                        sb.Append((char)code).Append((char)low);
                        i += 11;
                        break;
                    }
                    i += 5;
                    if (code < 0x20) sb.Append(code switch
                    {
                        0x08 => "\\b",
                        0x0C => "\\f",
                        0x0A => "\\n",
                        0x0D => "\\r",
                        0x09 => "\\t",
                        _ => "\\u" + code.ToString("x4", CultureInfo.InvariantCulture),
                    });
                    else if (code == '"') sb.Append("\\\"");
                    else if (code == '\\') sb.Append("\\\\");
                    else sb.Append((char)code);
                    break;
                case '\\' when i + 1 < json.Length:
                    // \" \\ \b \f \n \r \t: Swift writes the same escapes. Copied whole so "\\/" isn't misread.
                    sb.Append(c).Append(json[i + 1]);
                    i++;
                    break;
                default:
                    sb.Append(c);
                    break;
            }
        }
        return sb.ToString();
    }

    private static bool TryHex(string s, int start, out int value) =>
        int.TryParse(s.AsSpan(start, 4), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out value);

    internal static readonly JavaScriptEncoder Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping;
}

/// <summary>Source-generated metadata for every type Medley stores or relays.</summary>
[JsonSourceGenerationOptions(
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    Converters = [typeof(UppercaseGuidConverter)])]
[JsonSerializable(typeof(Track))]
[JsonSerializable(typeof(List<Track>))]
[JsonSerializable(typeof(Album))]
[JsonSerializable(typeof(Artist))]
[JsonSerializable(typeof(Playlist))]
[JsonSerializable(typeof(MediaItem))]
[JsonSerializable(typeof(List<MediaItem>))]
[JsonSerializable(typeof(Lyrics))]
[JsonSerializable(typeof(BrowseCacheFile))]
[JsonSerializable(typeof(AccountInfo))]
[JsonSerializable(typeof(PlaybackContext))]
[JsonSerializable(typeof(QueueEntry))]
[JsonSerializable(typeof(List<QueueEntry>))]
[JsonSerializable(typeof(PlayedTrack))]
[JsonSerializable(typeof(PlayerSnapshot))]
[JsonSerializable(typeof(PlaybackAnchor))]
[JsonSerializable(typeof(QueueWindow))]
[JsonSerializable(typeof(HandoffState))]
[JsonSerializable(typeof(SyncCommand))]
[JsonSerializable(typeof(SyncCommandKind))]
[JsonSerializable(typeof(CommandResult))]
[JsonSerializable(typeof(DeviceInfo))]
[JsonSerializable(typeof(SettingEntry))]
[JsonSerializable(typeof(List<SettingEntry>))]
[JsonSerializable(typeof(bool))]
[JsonSerializable(typeof(double))]
[JsonSerializable(typeof(int))]
[JsonSerializable(typeof(string))]
[JsonSerializable(typeof(List<string>))]
[JsonSerializable(typeof(LrcLibClient.Record))]
[JsonSerializable(typeof(List<LrcLibClient.Record>))]
public sealed partial class MedleyJsonContext : JsonSerializerContext
{
    private static MedleyJsonContext? _swift;

    /// <summary>The context with Swift-compatible text escaping. <see cref="JsonSerializerContext"/>'s
    /// <c>Default</c> escapes non-ASCII; this one doesn't.</summary>
    public static MedleyJsonContext Swift => _swift ??= new MedleyJsonContext(new JsonSerializerOptions(Default.Options) { Encoder = MedleyJson.Encoder });
}

/// <summary>UUIDs as Swift writes them: uppercase, hyphenated.</summary>
public sealed class UppercaseGuidConverter : JsonConverter<Guid>
{
    public override Guid Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        Guid.Parse(reader.GetString() ?? throw new JsonException("uuid"));

    public override void Write(Utf8JsonWriter writer, Guid value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToString("D").ToUpperInvariant());
}

/// <summary>Swift's default <c>Date</c> coding: a number of seconds since 2001-01-01T00:00:00Z.</summary>
public sealed class SwiftDateConverter : JsonConverter<DateTimeOffset>
{
    public static readonly DateTimeOffset ReferenceDate = new(2001, 1, 1, 0, 0, 0, TimeSpan.Zero);

    public override DateTimeOffset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        ReferenceDate.AddTicks((long)Math.Round(reader.GetDouble() * TimeSpan.TicksPerSecond));

    public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options) =>
        writer.WriteNumberValue((value - ReferenceDate).Ticks / (double)TimeSpan.TicksPerSecond);
}

/// <summary>Swift's synthesized coding of an enum with associated values: <c>{"track":{"_0":{…}}}</c>.</summary>
public sealed class MediaItemJsonConverter : JsonConverter<MediaItem>
{
    public override MediaItem Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        foreach (var prop in doc.RootElement.EnumerateObject())
        {
            var payload = prop.Value.GetProperty("_0");
            var ctx = MedleyJsonContext.Default;
            return prop.Name switch
            {
                "track" => MediaItem.Of(payload.Deserialize(ctx.Track)!),
                "album" => MediaItem.Of(payload.Deserialize(ctx.Album)!),
                "artist" => MediaItem.Of(payload.Deserialize(ctx.Artist)!),
                "playlist" => MediaItem.Of(payload.Deserialize(ctx.Playlist)!),
                _ => throw new JsonException($"unknown media item {prop.Name}"),
            };
        }
        throw new JsonException("empty media item");
    }

    public override void Write(Utf8JsonWriter writer, MediaItem value, JsonSerializerOptions options)
    {
        var ctx = MedleyJsonContext.Default;
        writer.WriteStartObject();
        switch (value)
        {
            case MediaItem.TrackItem t: Payload(writer, "track", () => JsonSerializer.Serialize(writer, t.Track, ctx.Track)); break;
            case MediaItem.AlbumItem a: Payload(writer, "album", () => JsonSerializer.Serialize(writer, a.Album, ctx.Album)); break;
            case MediaItem.ArtistItem a: Payload(writer, "artist", () => JsonSerializer.Serialize(writer, a.Artist, ctx.Artist)); break;
            case MediaItem.PlaylistItem p: Payload(writer, "playlist", () => JsonSerializer.Serialize(writer, p.Playlist, ctx.Playlist)); break;
        }
        writer.WriteEndObject();
    }

    private static void Payload(Utf8JsonWriter writer, string name, Action body)
    {
        writer.WritePropertyName(name);
        writer.WriteStartObject();
        writer.WritePropertyName("_0");
        body();
        writer.WriteEndObject();
    }
}
