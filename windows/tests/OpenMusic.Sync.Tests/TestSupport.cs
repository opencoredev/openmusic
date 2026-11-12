using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using OpenMusic.Sync.Convex;

namespace OpenMusic.Sync.Tests;

public sealed class FakeSocket : IWebSocketConnection
{
    private readonly object _lock = new();
    private readonly List<string> _sent = new();
    private bool _closed;
    private readonly Channel<WebSocketEvent> _events = Channel.CreateUnbounded<WebSocketEvent>();
    public ChannelReader<WebSocketEvent> Events => _events.Reader;

    public IReadOnlyList<string> Sent { get { lock (_lock) return _sent.ToList(); } }
    public bool IsClosed { get { lock (_lock) return _closed; } }

    public void Send(string text) { lock (_lock) _sent.Add(text); }

    public void Close()
    {
        lock (_lock)
        {
            if (_closed) return;
            _closed = true;
        }
        _events.Writer.TryWrite(new WebSocketEvent.Closed("closed by client"));
        _events.Writer.TryComplete();
    }

    public void Open() => _events.Writer.TryWrite(new WebSocketEvent.Opened());
    public void Receive(string text) => _events.Writer.TryWrite(new WebSocketEvent.Message(text));

    public void ServerClose(string reason = "network down")
    {
        lock (_lock) _closed = true;
        _events.Writer.TryWrite(new WebSocketEvent.Closed(reason));
        _events.Writer.TryComplete();
    }

    public IReadOnlyList<ConvexValue> Messages => Sent.Select(ConvexValue.Parse).ToList();
    public IReadOnlyList<ConvexValue> MessagesOfType(string type) => Messages.Where(m => m["type"]?.StringValue == type).ToList();
}

public sealed class FakeTransport : IWebSocketTransport
{
    private readonly object _lock = new();
    private readonly List<FakeSocket> _sockets = new();
    public volatile bool AutoFail;
    public IReadOnlyList<FakeSocket> Sockets { get { lock (_lock) return _sockets.ToList(); } }

    public (IWebSocketConnection Connection, ChannelReader<WebSocketEvent> Events) Connect(Uri url)
    {
        var socket = new FakeSocket();
        lock (_lock) _sockets.Add(socket);
        if (AutoFail) socket.ServerClose("refused");
        return (socket, socket.Events);
    }
}

public sealed record HttpRequestRecord(string Path, ConvexValue Body, IReadOnlyDictionary<string, string> Headers);

public sealed class FakeHttp : IHttpPoster
{
    private readonly object _lock = new();
    private readonly List<HttpRequestRecord> _requests = new();
    public Func<string, ConvexValue, ConvexValue> Respond { get; set; } = (_, _) => ConvexValue.Object(("status", ConvexValue.String("success")), ("value", ConvexValue.Null));
    /// <summary>Answers with the headers too, and may throw (no answer). Used instead of Respond when set.</summary>
    public Func<string, ConvexValue, IReadOnlyDictionary<string, string>, ConvexValue>? Handle { get; set; }
    public TimeSpan Delay { get; set; }

    public IReadOnlyList<HttpRequestRecord> Requests { get { lock (_lock) return _requests.ToList(); } }

    public async Task<(byte[] Body, int Status)> PostAsync(Uri url, byte[] body, IReadOnlyDictionary<string, string> headers, CancellationToken cancellationToken = default)
    {
        var parsed = ConvexValue.Parse(body);
        lock (_lock) _requests.Add(new HttpRequestRecord(url.AbsolutePath, parsed, new Dictionary<string, string>(headers)));
        if (Delay > TimeSpan.Zero) await Task.Delay(Delay, cancellationToken);
        var answer = Handle is { } h ? h(url.AbsolutePath, parsed, headers) : Respond(url.AbsolutePath, parsed);
        return (answer.JsonBytes(), 200);
    }
}

/// <summary>A token provider handing out the given tokens in order (the last one repeats). Null means signed out.</summary>
public sealed class FakeTokens(params string?[] tokens) : IAuthTokenProvider
{
    private readonly object _lock = new();
    private int _index;
    public int Calls;
    public List<bool> ForcedRefreshes { get; } = new();
    public Exception? Throw { get; set; }
    public TimeSpan Delay { get; set; }
    public Func<string?>? Next { get; set; }

    public async Task<string?> GetTokenAsync(bool forceRefresh, CancellationToken cancellationToken = default)
    {
        Interlocked.Increment(ref Calls);
        lock (_lock) ForcedRefreshes.Add(forceRefresh);
        if (Delay > TimeSpan.Zero) await Task.Delay(Delay, cancellationToken);
        if (Throw is { } e) throw e;
        if (Next is { } next) return next();
        lock (_lock)
        {
            var token = tokens[Math.Min(_index, tokens.Length - 1)];
            _index++;
            return token;
        }
    }
}

public static class TestUtil
{
    public static readonly Uri Deployment = new("https://example-123.convex.cloud");

    /// <summary>A JWT (unsigned) with the given subject and lifetime. The same arguments give the same text.</summary>
    public static string Jwt(string sub, double lifetimeSeconds = 3600, double issuedAt = 1_800_000_000)
    {
        static string Part(string json) => Base64Url.Encode(Encoding.UTF8.GetBytes(json));
        var iat = issuedAt.ToString(System.Globalization.CultureInfo.InvariantCulture);
        var exp = (issuedAt + lifetimeSeconds).ToString(System.Globalization.CultureInfo.InvariantCulture);
        return $"{Part("{\"alg\":\"RS256\"}")}.{Part($"{{\"sub\":\"{sub}\",\"iat\":{iat},\"exp\":{exp}}}")}.sig";
    }

    public static ConvexClientOptions FastOptions(int fallbackAfter = 3) => new()
    {
        InitialBackoff = TimeSpan.FromMilliseconds(10),
        MaxBackoff = TimeSpan.FromMilliseconds(40),
        PollInterval = TimeSpan.FromMilliseconds(50),
        FallbackAfterFailures = fallbackAfter,
        Jitter = false,
        AuthRetryDelay = TimeSpan.FromMilliseconds(20),
    };

    public static ConvexClient MakeClient(FakeTransport transport, FakeHttp? http = null, int fallbackAfter = 3, TimeSpan? mutationTimeout = null)
    {
        var options = FastOptions(fallbackAfter);
        if (mutationTimeout is { } t) options.MutationTimeout = t;
        return new ConvexClient(Deployment, transport, http ?? new FakeHttp(), options);
    }

    /// <summary>Polls until <paramref name="condition"/> holds (or ~5 s pass).</summary>
    public static async Task<bool> Eventually(Func<bool> condition, int timeoutMs = 5000)
    {
        var sw = Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < timeoutMs)
        {
            if (condition()) return true;
            await Task.Delay(5);
        }
        return condition();
    }

    /// <summary>Polls a condition evaluated on <paramref name="actor"/>.</summary>
    public static async Task<bool> Eventually(SyncActor actor, Func<bool> condition, int timeoutMs = 5000)
    {
        var sw = Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < timeoutMs)
        {
            if (await actor.Run(condition)) return true;
            await Task.Delay(5);
        }
        return await actor.Run(condition);
    }

    public static string Ts(ulong n) => new ConvexTimestamp(n).Encoded;

    public static string Transition((int QuerySet, ulong Ts) from, (int QuerySet, ulong Ts) to, params string[] modifications) =>
        Transition(from, to, 0, 0, modifications);

    public static string Transition((int QuerySet, ulong Ts) from, (int QuerySet, ulong Ts) to, int identityFrom, int identityTo, params string[] modifications) =>
        $"{{\"type\":\"Transition\",\"startVersion\":{{\"querySet\":{from.QuerySet},\"ts\":\"{Ts(from.Ts)}\",\"identity\":{identityFrom}}},\"endVersion\":{{\"querySet\":{to.QuerySet},\"ts\":\"{Ts(to.Ts)}\",\"identity\":{identityTo}}},\"modifications\":[{string.Join(",", modifications)}]}}";

    public static string Updated(int id, string value) => $"{{\"type\":\"QueryUpdated\",\"queryId\":{id},\"value\":{value},\"logLines\":[],\"journal\":null}}";

    public static string MutationOk(int requestId, string result, ulong ts) =>
        $"{{\"type\":\"MutationResponse\",\"requestId\":{requestId},\"success\":true,\"result\":{result},\"ts\":\"{Ts(ts)}\",\"logLines\":[]}}";
}
