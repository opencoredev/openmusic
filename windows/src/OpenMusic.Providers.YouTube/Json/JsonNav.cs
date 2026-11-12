using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace OpenMusic.Providers.YouTube.Json;

/// <summary>
/// Small, forgiving navigation helpers for InnerTube's deep and irregular payloads (Swift: JSONNav.swift).
/// Paths mix keys and integer indices: <c>node.O("contents", "0", "tabRenderer")</c>.
/// </summary>
internal static class JsonNav
{
    public static readonly JsonNodeOptions NodeOptions = new() { PropertyNameCaseInsensitive = false };
    public static readonly JsonDocumentOptions DocumentOptions = new() { AllowTrailingCommas = false, MaxDepth = 512 };

    public static JsonNode? Parse(ReadOnlySpan<byte> utf8) => JsonNode.Parse(utf8, NodeOptions, DocumentOptions);

    public static JsonNode? Parse(string text) => JsonNode.Parse(text, NodeOptions, DocumentOptions);

    public static JsonNode? Any(this JsonNode? node, params string[] path)
    {
        foreach (var key in path)
        {
            switch (node)
            {
                case JsonObject o:
                    node = o.TryGetPropertyValue(key, out var v) ? v : null;
                    break;
                case JsonArray a when int.TryParse(key, NumberStyles.None, CultureInfo.InvariantCulture, out var i) && i < a.Count:
                    node = a[i];
                    break;
                default:
                    return null;
            }
        }
        return node;
    }

    /// <summary>The object at <paramref name="path"/>, or null.</summary>
    public static JsonObject? O(this JsonNode? node, params string[] path) => node.Any(path) as JsonObject;

    /// <summary>The array at <paramref name="path"/>; empty when missing or not an array.</summary>
    public static IList<JsonNode?> A(this JsonNode? node, params string[] path) =>
        node.Any(path) is JsonArray a ? a : Array.Empty<JsonNode?>();

    public static string? S(this JsonNode? node, params string[] path) => AsString(node.Any(path));

    public static bool? B(this JsonNode? node, params string[] path) =>
        node.Any(path) is JsonValue v && v.GetValueKind() is JsonValueKind.True or JsonValueKind.False ? v.GetValue<bool>() : null;

    /// <summary>An integral number (Swift <c>as? Int</c>).</summary>
    public static long? L(this JsonNode? node, params string[] path) => Long(node.Any(path) as JsonValue);

    public static int? I(this JsonNode? node, params string[] path) =>
        Long(node.Any(path) as JsonValue) is { } n && n is >= int.MinValue and <= int.MaxValue ? (int)n : null;

    /// <summary>Any number (Swift <c>as? Double</c>, which an integral NSNumber also satisfies).</summary>
    public static double? D(this JsonNode? node, params string[] path) => Double(node.Any(path) as JsonValue);

    /// <summary>
    /// An integral JSON number. Parsed values convert to any numeric type, but a value built from a CLR number converts
    /// only to that exact type, so the text is the fallback.
    /// </summary>
    public static long? Long(JsonValue? v)
    {
        if (v == null || v.GetValueKind() != JsonValueKind.Number) return null;
        if (v.TryGetValue<long>(out var l)) return l;
        if (v.TryGetValue<int>(out var i)) return i;
        return long.TryParse(v.ToJsonString(), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var p) ? p : null;
    }

    public static double? Double(JsonValue? v)
    {
        if (v == null || v.GetValueKind() != JsonValueKind.Number) return null;
        if (v.TryGetValue<double>(out var d)) return d;
        return double.TryParse(v.ToJsonString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var p) ? p : null;
    }

    public static string? AsString(JsonNode? node) =>
        node is JsonValue v && v.GetValueKind() == JsonValueKind.String ? v.GetValue<string>() : null;

    /// <summary>True when the object has <paramref name="key"/>, even with a JSON null (Swift: NSNull is not nil).</summary>
    public static bool Has(this JsonObject? o, string key) => o != null && o.ContainsKey(key);

    /// <summary>Text of a <c>{runs: [...]}</c> or <c>{simpleText: ...}</c> node at <paramref name="path"/>.</summary>
    public static string? Text(this JsonNode? node, params string[] path) => YTText.Plain(node.Any(path) as JsonObject);

    /// <summary>The key of a renderer wrapper like <c>{"musicShelfRenderer": {...}}</c>.</summary>
    public static string? RendererKey(this JsonObject o)
    {
        foreach (var (k, _) in o)
        {
            if (k.EndsWith("Renderer", StringComparison.Ordinal) || k.EndsWith("ViewModel", StringComparison.Ordinal)) return k;
        }
        return null;
    }

    public static JsonObject? Obj(this JsonObject? o, string key) => o != null && o.TryGetPropertyValue(key, out var v) ? v as JsonObject : null;

    public static JsonNode? Get(this JsonObject? o, string key) => o != null && o.TryGetPropertyValue(key, out var v) ? v : null;
}

internal static class YTText
{
    public static string? Plain(JsonObject? node)
    {
        if (node == null) return null;
        if (JsonNav.AsString(node.Get("simpleText")) is { } simple) return simple;
        if (JsonNav.AsString(node.Get("content")) is { } content) return content;
        var joined = string.Concat(Runs(node).Select(r => JsonNav.AsString(r.Get("text"))).Where(t => t != null));
        return joined.Length == 0 ? null : joined;
    }

    public static List<JsonObject> Runs(JsonObject? node) =>
        node.A("runs").OfType<JsonObject>().ToList();

    /// <summary>Swift's <c>CharacterSet.whitespaces</c>: spaces and tabs, not newlines.</summary>
    public static bool IsInlineWhitespace(char c) => c == '\t' || char.GetUnicodeCategory(c) == UnicodeCategory.SpaceSeparator;

    public static string TrimInline(string s)
    {
        int start = 0, end = s.Length;
        while (start < end && IsInlineWhitespace(s[start])) start++;
        while (end > start && IsInlineWhitespace(s[end - 1])) end--;
        return s[start..end];
    }

    /// <summary>Parses "3:47" or "1:02:03" into seconds.</summary>
    public static double? Duration(string? text)
    {
        if (string.IsNullOrEmpty(text)) return null;
        var parts = TrimInline(text).Split(':', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length is < 2 or > 3) return null;
        long total = 0;
        foreach (var part in parts)
        {
            if (!SwiftInt(part, out var n) || !(part.Length <= 2 || total == 0)) return null;
            total = total * 60 + n;
        }
        return total;
    }

    /// <summary>Swift <c>Int(String)</c>: optional sign, ASCII digits only.</summary>
    public static bool SwiftInt(string s, out long value) =>
        long.TryParse(s, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out value) && s.Length > 0 && !char.IsWhiteSpace(s[0]);

    public static bool IsYear(string text) =>
        text.Length == 4 && SwiftInt(text, out var n) && n is >= 1800 and <= 2200;

    /// <summary>The leading number of "1,000 songs" → 1000.</summary>
    public static int? Number(string? text)
    {
        if (text == null) return null;
        var digits = new string(text.TakeWhile(c => char.IsDigit(c) || c == ',').Where(char.IsDigit).ToArray());
        return int.TryParse(digits, NumberStyles.None, CultureInfo.InvariantCulture, out var n) ? n : null;
    }
}

/// <summary>Walks a JSON tree in (roughly) document order, the way the Swift client does.</summary>
internal static class JsonWalk
{
    /// Dictionaries in Swift are unordered, so the Swift walker visits common container keys first and the rest
    /// alphabetically. Kept identical here so both clients pick the same "first" match.
    static readonly string[] Priority = ["header", "contents", "content", "tabs", "items", "continuationItems", "secondaryContents"];

    static int Rank(string key)
    {
        var i = Array.IndexOf(Priority, key);
        return i < 0 ? int.MaxValue : i;
    }

    static IEnumerable<KeyValuePair<string, JsonNode?>> SortedForWalk(JsonObject o)
    {
        if (o.Count <= 1) return o;
        var list = o.ToList();
        list.Sort((l, r) =>
        {
            var a = Rank(l.Key);
            var b = Rank(r.Key);
            return a == b ? string.CompareOrdinal(l.Key, r.Key) : a.CompareTo(b);
        });
        return list;
    }

    /// <summary>Every value stored under <paramref name="key"/>, depth first. Does not descend into matches.</summary>
    public static List<JsonNode?> All(string key, JsonNode? node, int limit = int.MaxValue)
    {
        var output = new List<JsonNode?>();
        Visit(node, key, limit, output);
        return output;
    }

    /// <summary>The same over a list of nodes (a Swift <c>[Any]</c>).</summary>
    public static List<JsonNode?> All(string key, IEnumerable<JsonNode?> nodes, int limit = int.MaxValue)
    {
        var output = new List<JsonNode?>();
        foreach (var n in nodes)
        {
            if (output.Count >= limit) break;
            Visit(n, key, limit, output);
        }
        return output;
    }

    static void Visit(JsonNode? node, string key, int limit, List<JsonNode?> output)
    {
        if (output.Count >= limit) return;
        switch (node)
        {
            case JsonObject o:
                foreach (var (k, v) in SortedForWalk(o))
                {
                    if (k == key)
                    {
                        output.Add(v);
                        if (output.Count >= limit) return;
                    }
                    else
                    {
                        Visit(v, key, limit, output);
                        if (output.Count >= limit) return;
                    }
                }
                break;
            case JsonArray a:
                foreach (var v in a)
                {
                    Visit(v, key, limit, output);
                    if (output.Count >= limit) return;
                }
                break;
        }
    }

    public static JsonNode? First(string key, JsonNode? node) => All(key, node, 1).FirstOrDefault();

    public static JsonObject? FirstObject(string key, JsonNode? node) => First(key, node) as JsonObject;

    public static JsonObject? FirstObject(string key, IEnumerable<JsonNode?> nodes) => All(key, nodes, 1).FirstOrDefault() as JsonObject;
}
