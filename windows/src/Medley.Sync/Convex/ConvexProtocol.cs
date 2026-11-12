using System.Text.Json;

namespace Medley.Sync.Convex;

// The Convex WebSocket sync protocol, as spoken by convex/src/browser/sync/protocol.ts (npm `convex` 1.49) and by
// Sources/MedleySync/Convex/ConvexProtocol.swift. Client messages are JSON objects with a `type`; timestamps (`ts`) are
// u64 sent as base64 of 8 little-endian bytes.

/// <summary>A server timestamp. Compared numerically; sent back as its base64 text.</summary>
public readonly record struct ConvexTimestamp(ulong Value) : IComparable<ConvexTimestamp>
{
    public static readonly ConvexTimestamp Zero = new(0);
    public string Encoded => ConvexValue.Base64LE(Value);
    public static ConvexTimestamp? FromEncoded(string text) => ConvexValue.BitsFromBase64LE(text) is { } bits ? new ConvexTimestamp(bits) : null;
    public int CompareTo(ConvexTimestamp other) => Value.CompareTo(other.Value);
    public static bool operator <(ConvexTimestamp a, ConvexTimestamp b) => a.Value < b.Value;
    public static bool operator >(ConvexTimestamp a, ConvexTimestamp b) => a.Value > b.Value;
    public static bool operator <=(ConvexTimestamp a, ConvexTimestamp b) => a.Value <= b.Value;
    public static bool operator >=(ConvexTimestamp a, ConvexTimestamp b) => a.Value >= b.Value;
}

public readonly record struct StateVersion(int QuerySet, ConvexTimestamp Ts, int Identity)
{
    public static readonly StateVersion Initial = new(0, ConvexTimestamp.Zero, 0);
}

public abstract record QueryModification(int QueryId)
{
    public sealed record Updated(int QueryId, ConvexValue Value, string? Journal) : QueryModification(QueryId);
    public sealed record Failed(int QueryId, string Message, ConvexValue? Data, string? Journal) : QueryModification(QueryId);
    public sealed record Removed(int QueryId) : QueryModification(QueryId);
}

public abstract record ServerMessage
{
    public sealed record Transition(StateVersion Start, StateVersion End, IReadOnlyList<QueryModification> Modifications) : ServerMessage;
    public sealed record TransitionChunk(string Chunk, int PartNumber, int TotalParts, string TransitionId) : ServerMessage;
    public sealed record MutationSuccess(int RequestId, ConvexValue Value, ConvexTimestamp Ts) : ServerMessage;
    public sealed record MutationFailure(int RequestId, string Message, ConvexValue? Data) : ServerMessage;
    public sealed record ActionSuccess(int RequestId, ConvexValue Value) : ServerMessage;
    public sealed record ActionFailure(int RequestId, string Message, ConvexValue? Data) : ServerMessage;
    /// <summary><c>BaseVersion</c> is the identity version the error is about; <c>AuthUpdateAttempted</c> says it answers an Authenticate.</summary>
    public sealed record AuthError(string Error, int? BaseVersion, bool AuthUpdateAttempted) : ServerMessage;
    public sealed record FatalError(string Error) : ServerMessage;
    public sealed record Ping : ServerMessage;

    public static ServerMessage Parse(string text)
    {
        JsonDocument doc;
        try { doc = JsonDocument.Parse(text); }
        catch (JsonException e) { throw new ConvexValueException($"Server message is not JSON: {e.Message}"); }
        using (doc)
        {
            var o = doc.RootElement;
            if (o.ValueKind != JsonValueKind.Object || !o.TryGetProperty("type", out var typeEl) || typeEl.ValueKind != JsonValueKind.String)
                throw new ConvexValueException("Server message is not an object with a type");
            var type = typeEl.GetString()!;

            int Int(JsonElement d, string key) =>
                d.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Number ? (int)v.GetDouble() : throw new ConvexValueException($"{type}.{key} is missing");
            string Str(JsonElement d, string key) =>
                d.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString()! : throw new ConvexValueException($"{type}.{key} is missing");
            string? OptStr(JsonElement d, string key) =>
                d.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
            ConvexTimestamp Ts(JsonElement d, string key) =>
                ConvexTimestamp.FromEncoded(Str(d, key)) ?? throw new ConvexValueException($"{type}.{key} is malformed");
            StateVersion Version(string key) =>
                o.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Object
                    ? new StateVersion(Int(v, "querySet"), Ts(v, "ts"), Int(v, "identity"))
                    : throw new ConvexValueException($"{type}.{key} is missing");
            ConvexValue? OptValue(JsonElement d, string key) =>
                d.TryGetProperty(key, out var v) && v.ValueKind != JsonValueKind.Null && v.ValueKind != JsonValueKind.Undefined ? ConvexValue.FromJson(v) : null;
            ConvexValue Value(JsonElement d, string key) => d.TryGetProperty(key, out var v) ? ConvexValue.FromJson(v) : ConvexValue.Null;
            bool Bool(string key) => o.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.True;

            switch (type)
            {
                case "Ping": return new Ping();
                case "Transition":
                    var mods = new List<QueryModification>();
                    if (o.TryGetProperty("modifications", out var list) && list.ValueKind == JsonValueKind.Array)
                    {
                        foreach (var m in list.EnumerateArray())
                        {
                            var id = Int(m, "queryId");
                            mods.Add(OptStr(m, "type") switch
                            {
                                "QueryUpdated" => new QueryModification.Updated(id, Value(m, "value"), OptStr(m, "journal")),
                                "QueryFailed" => new QueryModification.Failed(id, OptStr(m, "errorMessage") ?? "Query failed", OptValue(m, "errorData"), OptStr(m, "journal")),
                                "QueryRemoved" => new QueryModification.Removed(id),
                                var t => throw new ConvexValueException($"Unknown modification {t ?? "nil"}"),
                            });
                        }
                    }
                    return new Transition(Version("startVersion"), Version("endVersion"), mods);
                case "TransitionChunk":
                    return new TransitionChunk(Str(o, "chunk"), Int(o, "partNumber"), Int(o, "totalParts"), Str(o, "transitionId"));
                case "MutationResponse":
                    if (Bool("success")) return new MutationSuccess(Int(o, "requestId"), Value(o, "result"), Ts(o, "ts"));
                    return new MutationFailure(Int(o, "requestId"), OptStr(o, "result") ?? "Mutation failed", OptValue(o, "errorData"));
                case "ActionResponse":
                    if (Bool("success")) return new ActionSuccess(Int(o, "requestId"), Value(o, "result"));
                    return new ActionFailure(Int(o, "requestId"), OptStr(o, "result") ?? "Action failed", OptValue(o, "errorData"));
                case "AuthError":
                    int? baseVersion = o.TryGetProperty("baseVersion", out var bv) && bv.ValueKind == JsonValueKind.Number ? (int)bv.GetDouble() : null;
                    return new AuthError(OptStr(o, "error") ?? "", baseVersion, Bool("authUpdateAttempted"));
                case "FatalError": return new FatalError(OptStr(o, "error") ?? "");
                default: throw new ConvexValueException($"Unknown server message {type}");
            }
        }
    }
}

/// <summary>Builders for the client's messages, byte-for-byte what the Swift client sends (sorted keys).</summary>
public static class ClientMessage
{
    public static string Connect(string sessionId, int connectionCount, string? lastCloseReason, ConvexTimestamp? maxObservedTimestamp, double clientTs)
    {
        var fields = new Dictionary<string, ConvexValue>
        {
            ["type"] = ConvexValue.String("Connect"),
            ["sessionId"] = ConvexValue.String(sessionId),
            ["connectionCount"] = ConvexValue.Float64(connectionCount),
            ["lastCloseReason"] = ConvexValue.OptionalString(lastCloseReason),
            ["clientTs"] = ConvexValue.Float64(Math.Round(clientTs)),
        };
        if (maxObservedTimestamp is { } ts) fields["maxObservedTimestamp"] = ConvexValue.String(ts.Encoded);
        return ConvexValue.Object(fields).JsonString();
    }

    public readonly record struct Add(int QueryId, string Path, ConvexValue Args, string? Journal = null);

    public static string ModifyQuerySet(int baseVersion, int newVersion, IEnumerable<Add> adds, IEnumerable<int> removes)
    {
        var modifications = adds.Select(add =>
        {
            var m = new Dictionary<string, ConvexValue>
            {
                ["type"] = ConvexValue.String("Add"),
                ["queryId"] = ConvexValue.Float64(add.QueryId),
                ["udfPath"] = ConvexValue.String(add.Path),
                ["args"] = ConvexValue.Array(add.Args),
            };
            if (add.Journal is { } journal) m["journal"] = ConvexValue.String(journal);
            return ConvexValue.Object(m);
        }).Concat(removes.Select(id => ConvexValue.Object(("type", ConvexValue.String("Remove")), ("queryId", ConvexValue.Float64(id)))));
        return ConvexValue.Object(
            ("type", ConvexValue.String("ModifyQuerySet")),
            ("baseVersion", ConvexValue.Float64(baseVersion)),
            ("newVersion", ConvexValue.Float64(newVersion)),
            ("modifications", ConvexValue.Array(modifications))).JsonString();
    }

    public static string Mutation(int requestId, string path, ConvexValue args) => ConvexValue.Object(
        ("type", ConvexValue.String("Mutation")),
        ("requestId", ConvexValue.Float64(requestId)),
        ("udfPath", ConvexValue.String(path)),
        ("args", ConvexValue.Array(args))).JsonString();

    public static string Action(int requestId, string path, ConvexValue args) => ConvexValue.Object(
        ("type", ConvexValue.String("Action")),
        ("requestId", ConvexValue.Float64(requestId)),
        ("udfPath", ConvexValue.String(path)),
        ("args", ConvexValue.Array(args))).JsonString();

    /// <summary>Authenticate with a user token. <paramref name="baseVersion"/> is the identity version before it.</summary>
    public static string Authenticate(string token, int baseVersion) => ConvexValue.Object(
        ("type", ConvexValue.String("Authenticate")),
        ("tokenType", ConvexValue.String("User")),
        ("value", ConvexValue.String(token)),
        ("baseVersion", ConvexValue.Float64(baseVersion))).JsonString();

    /// <summary>Authenticate with no token: drops the identity on an open socket.</summary>
    public static string AuthenticateNone(int baseVersion) => ConvexValue.Object(
        ("type", ConvexValue.String("Authenticate")),
        ("tokenType", ConvexValue.String("None")),
        ("baseVersion", ConvexValue.Float64(baseVersion))).JsonString();

    /// <summary><c>module:function</c>, the canonical form the sync protocol uses ("devices" → "devices:default").</summary>
    public static string CanonicalUdfPath(string path)
    {
        var p = path.EndsWith(".js", StringComparison.Ordinal) ? path[..^3] : path;
        return p.Contains(':') ? p : $"{p}:default";
    }
}
