using System.Buffers.Binary;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace OpenMusic.Sync.Convex;

public enum ConvexKind { Null, Bool, Int64, Float64, String, Bytes, Array, Object }

/// <summary>
/// A Convex value, encoded on the wire as Convex JSON (<c>convexToJson</c> in the npm package): numbers are float64,
/// int64 travels as <c>{"$integer": base64(8 bytes LE)}</c>, bytes as <c>{"$bytes": base64}</c>, and floats JSON can't
/// spell (NaN, ±Infinity, -0) as <c>{"$float": base64(8 bytes LE)}</c>. Mirrors <c>ConvexValue.swift</c>, including
/// its text form (sorted object keys, integer-valued doubles written without a fraction).
/// </summary>
public sealed class ConvexValue : IEquatable<ConvexValue>
{
    public ConvexKind Kind { get; }
    private readonly bool _bool;
    private readonly long _int;
    private readonly double _double;
    private readonly string? _string;
    private readonly byte[]? _bytes;
    private readonly IReadOnlyList<ConvexValue>? _array;
    private readonly IReadOnlyDictionary<string, ConvexValue>? _object;

    private ConvexValue(ConvexKind kind, bool b = false, long i = 0, double d = 0, string? s = null, byte[]? bytes = null,
                        IReadOnlyList<ConvexValue>? array = null, IReadOnlyDictionary<string, ConvexValue>? obj = null)
    {
        Kind = kind; _bool = b; _int = i; _double = d; _string = s; _bytes = bytes; _array = array; _object = obj;
    }

    public static readonly ConvexValue Null = new(ConvexKind.Null);
    public static ConvexValue Bool(bool value) => new(ConvexKind.Bool, b: value);
    public static ConvexValue Int64(long value) => new(ConvexKind.Int64, i: value);
    public static ConvexValue Float64(double value) => new(ConvexKind.Float64, d: value);
    public static ConvexValue String(string value) => new(ConvexKind.String, s: value);
    public static ConvexValue Bytes(byte[] value) => new(ConvexKind.Bytes, bytes: value.ToArray());
    public static ConvexValue Array(IEnumerable<ConvexValue> items) => new(ConvexKind.Array, array: items.ToList());
    public static ConvexValue Array(params ConvexValue[] items) => new(ConvexKind.Array, array: items.ToList());
    public static ConvexValue Object(IEnumerable<KeyValuePair<string, ConvexValue>> fields) =>
        new(ConvexKind.Object, obj: new Dictionary<string, ConvexValue>(fields, StringComparer.Ordinal));
    public static ConvexValue Object(params (string Key, ConvexValue Value)[] fields) =>
        Object(fields.Select(f => new KeyValuePair<string, ConvexValue>(f.Key, f.Value)));
    public static ConvexValue OptionalString(string? value) => value is null ? Null : String(value);

    public bool IsNull => Kind == ConvexKind.Null;

    /// <summary>The field <paramref name="key"/> of an object, else null.</summary>
    public ConvexValue? this[string key] => Kind == ConvexKind.Object && _object!.TryGetValue(key, out var v) ? v : null;

    public string? StringValue => Kind == ConvexKind.String ? _string : null;
    public bool? BoolValue => Kind == ConvexKind.Bool ? _bool : null;
    public double? DoubleValue => Kind switch { ConvexKind.Float64 => _double, ConvexKind.Int64 => _int, _ => null };
    public long? Int64Value => Kind == ConvexKind.Int64 ? _int : null;
    public byte[]? BytesValue => Kind == ConvexKind.Bytes ? _bytes!.ToArray() : null;
    public IReadOnlyList<ConvexValue>? ArrayValue => Kind == ConvexKind.Array ? _array : null;
    public IReadOnlyDictionary<string, ConvexValue>? ObjectValue => Kind == ConvexKind.Object ? _object : null;

    // MARK: Equality

    public bool Equals(ConvexValue? other)
    {
        if (other is null || other.Kind != Kind) return false;
        return Kind switch
        {
            ConvexKind.Null => true,
            ConvexKind.Bool => _bool == other._bool,
            ConvexKind.Int64 => _int == other._int,
            ConvexKind.Float64 => _double.Equals(other._double),
            ConvexKind.String => _string == other._string,
            ConvexKind.Bytes => _bytes!.AsSpan().SequenceEqual(other._bytes),
            ConvexKind.Array => _array!.Count == other._array!.Count && _array.Zip(other._array).All(p => p.First.Equals(p.Second)),
            ConvexKind.Object => _object!.Count == other._object!.Count
                && _object.All(kv => other._object.TryGetValue(kv.Key, out var o) && kv.Value.Equals(o)),
            _ => false,
        };
    }

    public override bool Equals(object? obj) => obj is ConvexValue v && Equals(v);
    public override int GetHashCode() => JsonString().GetHashCode(StringComparison.Ordinal);
    public static bool operator ==(ConvexValue? a, ConvexValue? b) => a is null ? b is null : a.Equals(b);
    public static bool operator !=(ConvexValue? a, ConvexValue? b) => !(a == b);
    public override string ToString() => JsonString();

    // MARK: Encoding to Convex JSON text

    /// <summary>The Convex JSON text of this value, with object keys sorted (ordinal) as the Swift client writes them.</summary>
    public string JsonString()
    {
        var sb = new StringBuilder();
        Write(sb);
        return sb.ToString();
    }

    public byte[] JsonBytes() => Encoding.UTF8.GetBytes(JsonString());

    private void Write(StringBuilder sb)
    {
        switch (Kind)
        {
            case ConvexKind.Null: sb.Append("null"); break;
            case ConvexKind.Bool: sb.Append(_bool ? "true" : "false"); break;
            case ConvexKind.Int64: sb.Append("{\"$integer\":\"").Append(Base64LE(unchecked((ulong)_int))).Append("\"}"); break;
            case ConvexKind.Float64:
                if (double.IsNaN(_double) || double.IsInfinity(_double) || (_double == 0 && double.IsNegative(_double)))
                    sb.Append("{\"$float\":\"").Append(Base64LE(unchecked((ulong)BitConverter.DoubleToInt64Bits(_double)))).Append("\"}");
                else sb.Append(FormatNumber(_double));
                break;
            case ConvexKind.String: WriteString(_string!, sb); break;
            case ConvexKind.Bytes: sb.Append("{\"$bytes\":\"").Append(Convert.ToBase64String(_bytes!)).Append("\"}"); break;
            case ConvexKind.Array:
                sb.Append('[');
                for (var i = 0; i < _array!.Count; i++)
                {
                    if (i > 0) sb.Append(',');
                    _array[i].Write(sb);
                }
                sb.Append(']');
                break;
            case ConvexKind.Object:
                sb.Append('{');
                var first = true;
                foreach (var key in _object!.Keys.OrderBy(k => k, StringComparer.Ordinal))
                {
                    if (!first) sb.Append(',');
                    first = false;
                    WriteString(key, sb);
                    sb.Append(':');
                    _object[key].Write(sb);
                }
                sb.Append('}');
                break;
        }
    }

    internal static string FormatNumber(double d)
    {
        if (d == Math.Round(d) && Math.Abs(d) < 9_007_199_254_740_992d) return ((long)d).ToString(CultureInfo.InvariantCulture);
        return d.ToString("R", CultureInfo.InvariantCulture);
    }

    private static void WriteString(string s, StringBuilder sb)
    {
        sb.Append('"');
        foreach (var c in s)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                default:
                    if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    else sb.Append(c);
                    break;
            }
        }
        sb.Append('"');
    }

    internal static string Base64LE(ulong bits)
    {
        Span<byte> buffer = stackalloc byte[8];
        BinaryPrimitives.WriteUInt64LittleEndian(buffer, bits);
        return Convert.ToBase64String(buffer);
    }

    internal static ulong? BitsFromBase64LE(string text)
    {
        try
        {
            var data = Convert.FromBase64String(text);
            if (data.Length != 8) return null;
            return BinaryPrimitives.ReadUInt64LittleEndian(data);
        }
        catch (FormatException) { return null; }
    }

    // MARK: Decoding from Convex JSON

    /// <summary>Parses Convex JSON text, decoding <c>$integer</c>, <c>$float</c> and <c>$bytes</c>.</summary>
    public static ConvexValue Parse(string text)
    {
        try
        {
            using var doc = JsonDocument.Parse(text);
            return FromJson(doc.RootElement);
        }
        catch (JsonException e) { throw new ConvexValueException($"Invalid JSON: {e.Message}"); }
    }

    public static ConvexValue Parse(ReadOnlySpan<byte> utf8)
    {
        try
        {
            var reader = new Utf8JsonReader(utf8);
            using var doc = JsonDocument.ParseValue(ref reader);
            return FromJson(doc.RootElement);
        }
        catch (JsonException e) { throw new ConvexValueException($"Invalid JSON: {e.Message}"); }
    }

    public static ConvexValue FromJson(JsonElement e)
    {
        switch (e.ValueKind)
        {
            case JsonValueKind.Null: return Null;
            case JsonValueKind.True: return Bool(true);
            case JsonValueKind.False: return Bool(false);
            case JsonValueKind.Number: return Float64(e.GetDouble());
            case JsonValueKind.String: return String(e.GetString()!);
            case JsonValueKind.Array: return Array(e.EnumerateArray().Select(FromJson).ToList());
            case JsonValueKind.Object:
                var props = e.EnumerateObject().ToList();
                if (props.Count == 1 && props[0].Name.StartsWith('$'))
                {
                    var key = props[0].Name;
                    if (props[0].Value.ValueKind != JsonValueKind.String) throw new ConvexValueException($"Malformed {key} field");
                    var text = props[0].Value.GetString()!;
                    switch (key)
                    {
                        case "$integer":
                            return Int64(unchecked((long)(BitsFromBase64LE(text) ?? throw new ConvexValueException("Malformed $integer"))));
                        case "$float":
                            return Float64(BitConverter.Int64BitsToDouble(unchecked((long)(BitsFromBase64LE(text) ?? throw new ConvexValueException("Malformed $float")))));
                        case "$bytes":
                            try { return Bytes(Convert.FromBase64String(text)); }
                            catch (FormatException) { throw new ConvexValueException("Malformed $bytes"); }
                        default: throw new ConvexValueException($"Unsupported Convex type {key}");
                    }
                }
                var fields = new Dictionary<string, ConvexValue>(StringComparer.Ordinal);
                foreach (var p in props) fields[p.Name] = FromJson(p.Value);
                return new ConvexValue(ConvexKind.Object, obj: fields);
            default: throw new ConvexValueException($"Unexpected JSON value {e.ValueKind}");
        }
    }

    // MARK: Typed bridge (System.Text.Json)

    /// <summary>Encodes a value through System.Text.Json (<see cref="Wire.Options"/>). Numbers become float64, as <c>v.number()</c> expects.</summary>
    public static ConvexValue Encode<T>(T value) => Parse(JsonSerializer.Serialize(value, Wire.Options));

    /// <summary>Decodes into <typeparamref name="T"/> through System.Text.Json. int64 becomes a JSON integer and bytes base64.</summary>
    public T Decode<T>()
    {
        var node = PlainJson();
        return node.Deserialize<T>(Wire.Options)!;
    }

    /// <summary>Plain JSON (no Convex types) of this value.</summary>
    public JsonNode? PlainJson() => Kind switch
    {
        ConvexKind.Null => null,
        ConvexKind.Bool => JsonValue.Create(_bool),
        ConvexKind.Int64 => JsonValue.Create(_int),
        ConvexKind.Float64 => double.IsFinite(_double) ? JsonValue.Create(_double) : throw new ConvexValueException($"{_double} has no JSON form"),
        ConvexKind.String => JsonValue.Create(_string),
        ConvexKind.Bytes => JsonValue.Create(Convert.ToBase64String(_bytes!)),
        ConvexKind.Array => new JsonArray(_array!.Select(v => v.PlainJson()).ToArray()),
        ConvexKind.Object => new JsonObject(_object!.Select(kv => new KeyValuePair<string, JsonNode?>(kv.Key, kv.Value.PlainJson()))),
        _ => null,
    };
}

public sealed class ConvexValueException(string message) : Exception(message);
