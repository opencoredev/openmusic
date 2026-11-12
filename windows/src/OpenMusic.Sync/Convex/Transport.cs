using System.Net.WebSockets;
using System.Text;
using System.Threading.Channels;

namespace OpenMusic.Sync.Convex;

/// <summary>What a socket reports, in order. <see cref="Closed"/> is always the last event.</summary>
public abstract record WebSocketEvent
{
    public sealed record Opened : WebSocketEvent;
    public sealed record Message(string Text) : WebSocketEvent;
    public sealed record Closed(string Reason) : WebSocketEvent;
}

/// <summary>One open (or opening) socket. Calls never block.</summary>
public interface IWebSocketConnection
{
    void Send(string text);
    void Close();
}

/// <summary>Opens sockets. Swapped for a fake in tests.</summary>
public interface IWebSocketTransport
{
    (IWebSocketConnection Connection, ChannelReader<WebSocketEvent> Events) Connect(Uri url);
}

/// <summary>POSTs JSON. Swapped for a fake in tests.</summary>
public interface IHttpPoster
{
    Task<(byte[] Body, int Status)> PostAsync(Uri url, byte[] body, IReadOnlyDictionary<string, string> headers, CancellationToken cancellationToken = default);
}

public static class OpenMusicSyncInfo
{
    public const string Version = "0.1.0";
    /// <summary>The <c>Convex-Client</c> header value.</summary>
    public static string ClientHeader => $"medley-csharp-{Version}";
}

/// <summary><see cref="ClientWebSocket"/> sockets.</summary>
public sealed class ClientWebSocketTransport : IWebSocketTransport
{
    public (IWebSocketConnection Connection, ChannelReader<WebSocketEvent> Events) Connect(Uri url)
    {
        var channel = Channel.CreateUnbounded<WebSocketEvent>(new UnboundedChannelOptions { SingleReader = true });
        var connection = new ClientWebSocketConnection(url, channel.Writer);
        connection.Start();
        return (connection, channel.Reader);
    }
}

internal sealed class ClientWebSocketConnection(Uri url, ChannelWriter<WebSocketEvent> events) : IWebSocketConnection
{
    private readonly ClientWebSocket _socket = new();
    private readonly CancellationTokenSource _cts = new();
    private readonly Channel<string> _outbox = Channel.CreateUnbounded<string>(new UnboundedChannelOptions { SingleReader = true });
    private int _finished;

    public void Start()
    {
        _socket.Options.SetRequestHeader("Convex-Client", OpenMusicSyncInfo.ClientHeader);
        _socket.Options.KeepAliveInterval = TimeSpan.FromSeconds(30);
        _ = Task.Run(RunAsync);
    }

    private async Task RunAsync()
    {
        try
        {
            using var connectTimeout = CancellationTokenSource.CreateLinkedTokenSource(_cts.Token);
            connectTimeout.CancelAfter(TimeSpan.FromSeconds(30));
            await _socket.ConnectAsync(url, connectTimeout.Token).ConfigureAwait(false);
        }
        catch (Exception e)
        {
            Finish(_cts.IsCancellationRequested ? "closed by client" : e.Message);
            return;
        }
        events.TryWrite(new WebSocketEvent.Opened());
        _ = Task.Run(SendLoopAsync);
        var buffer = new byte[64 * 1024];
        var message = new MemoryStream();
        try
        {
            while (!_cts.IsCancellationRequested)
            {
                var result = await _socket.ReceiveAsync(buffer, _cts.Token).ConfigureAwait(false);
                if (result.MessageType == WebSocketMessageType.Close)
                {
                    Finish($"server closed ({(int?)result.CloseStatus ?? 0})");
                    return;
                }
                message.Write(buffer, 0, result.Count);
                if (message.Length > 16 * 1024 * 1024) { Finish("message too large"); return; }
                if (!result.EndOfMessage) continue;
                var text = Encoding.UTF8.GetString(message.GetBuffer(), 0, (int)message.Length);
                message.SetLength(0);
                if (Volatile.Read(ref _finished) == 0) events.TryWrite(new WebSocketEvent.Message(text));
            }
        }
        catch (Exception e)
        {
            Finish(_cts.IsCancellationRequested ? "closed by client" : e.Message);
        }
    }

    private async Task SendLoopAsync()
    {
        try
        {
            await foreach (var text in _outbox.Reader.ReadAllAsync(_cts.Token).ConfigureAwait(false))
            {
                await _socket.SendAsync(Encoding.UTF8.GetBytes(text), WebSocketMessageType.Text, true, _cts.Token).ConfigureAwait(false);
            }
        }
        catch (Exception e)
        {
            Finish(_cts.IsCancellationRequested ? "closed by client" : $"send failed: {e.Message}");
        }
    }

    public void Send(string text) => _outbox.Writer.TryWrite(text);

    public void Close()
    {
        if (Volatile.Read(ref _finished) == 0 && _socket.State == WebSocketState.Open)
        {
            _ = _socket.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, null, CancellationToken.None).ContinueWith(_ => { }, TaskScheduler.Default);
        }
        Finish("closed by client");
    }

    private void Finish(string reason)
    {
        if (Interlocked.Exchange(ref _finished, 1) != 0) return;
        events.TryWrite(new WebSocketEvent.Closed(reason));
        events.TryComplete();
        _outbox.Writer.TryComplete();
        _cts.Cancel();
        _ = Task.Delay(1000).ContinueWith(_ => _socket.Dispose(), TaskScheduler.Default);
    }
}

/// <summary><see cref="HttpClient"/> POSTs, 20 s timeout.</summary>
public sealed class HttpClientPoster(HttpClient? client = null) : IHttpPoster
{
    private readonly HttpClient _client = client ?? new HttpClient(new SocketsHttpHandler { UseCookies = false }) { Timeout = TimeSpan.FromSeconds(20) };

    public async Task<(byte[] Body, int Status)> PostAsync(Uri url, byte[] body, IReadOnlyDictionary<string, string> headers, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, url) { Content = new ByteArrayContent(body) };
        foreach (var (key, value) in headers)
        {
            if (key.Equals("Content-Type", StringComparison.OrdinalIgnoreCase)) request.Content.Headers.TryAddWithoutValidation(key, value);
            else request.Headers.TryAddWithoutValidation(key, value);
        }
        using var response = await _client.SendAsync(request, cancellationToken).ConfigureAwait(false);
        return (await response.Content.ReadAsByteArrayAsync(cancellationToken).ConfigureAwait(false), (int)response.StatusCode);
    }
}
