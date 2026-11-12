using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace OpenMusic.Providers.YouTube.Json;

/// <summary>
/// Writes JSON byte-for-byte the way Swift's <c>JSONEncoder</c> with <c>.sortedKeys</c> does (checked against its
/// output on macOS 27 and Linux, fixture <c>transfer_*.json</c>): keys in ordinal order, <c>/</c> escaped as <c>\/</c>,
/// control characters as <c>\n \r \t \b \f</c> or <c>\u00xx</c>, everything else (non-ASCII, DEL, U+2028) raw UTF-8.
/// The sign-in transfer relies on stable bytes, so an unchanged sign-in is never uploaded twice.
/// </summary>
internal static class SwiftJson
{
    public static string Serialize(JsonNode? node)
    {
        var sb = new StringBuilder();
        Write(sb, node);
        return sb.ToString();
    }

    public static byte[] SerializeToUtf8(JsonNode? node) => Encoding.UTF8.GetBytes(Serialize(node));

    static void Write(StringBuilder sb, JsonNode? node)
    {
        switch (node)
        {
            case null:
                sb.Append("null");
                break;
            case JsonObject o:
                sb.Append('{');
                var first = true;
                foreach (var (k, v) in o.OrderBy(kv => kv.Key, StringComparer.Ordinal))
                {
                    if (!first) sb.Append(',');
                    first = false;
                    WriteString(sb, k);
                    sb.Append(':');
                    Write(sb, v);
                }
                sb.Append('}');
                break;
            case JsonArray a:
                sb.Append('[');
                for (var i = 0; i < a.Count; i++)
                {
                    if (i > 0) sb.Append(',');
                    Write(sb, a[i]);
                }
                sb.Append(']');
                break;
            case JsonValue v:
                switch (v.GetValueKind())
                {
                    case JsonValueKind.String: WriteString(sb, v.GetValue<string>()); break;
                    case JsonValueKind.True: sb.Append("true"); break;
                    case JsonValueKind.False: sb.Append("false"); break;
                    case JsonValueKind.Null: sb.Append("null"); break;
                    case JsonValueKind.Number:
                        // Integers as plain digits (all the payloads hold); anything else as System.Text.Json writes it.
                        sb.Append(JsonNav.Long(v) is { } l ? l.ToString(CultureInfo.InvariantCulture) : v.ToJsonString());
                        break;
                    default: sb.Append(v.ToJsonString()); break;
                }
                break;
        }
    }

    static void WriteString(StringBuilder sb, string s)
    {
        sb.Append('"');
        foreach (var c in s)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '/': sb.Append("\\/"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                case '\b': sb.Append("\\b"); break;
                case '\f': sb.Append("\\f"); break;
                default:
                    if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    else sb.Append(c);
                    break;
            }
        }
        sb.Append('"');
    }
}
