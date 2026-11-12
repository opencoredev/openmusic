using System.Collections.Concurrent;
using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using Medley.Providers.YouTube.Json;

namespace Medley.Providers.YouTube.Tests;

/// <summary>One request as the fake server saw it.</summary>
internal sealed record SeenRequest(HttpMethod Method, Uri Url, string Body, IReadOnlyDictionary<string, string> Headers)
{
    public JsonObject? Json => Body.Length > 0 ? JsonNav.Parse(Body) as JsonObject : null;

    /// <summary>The InnerTube client name in the request's context.</summary>
    public string? ClientName => Json.S("context", "client", "clientName");
}

/// <summary>A fake HTTP server: every request goes to <see cref="Respond"/>, and is recorded.</summary>
internal sealed class FakeHandler(Func<SeenRequest, Task<HttpResponseMessage>> respond) : HttpMessageHandler
{
    public ConcurrentQueue<SeenRequest> Requests { get; } = new();

    public FakeHandler(Func<SeenRequest, HttpResponseMessage> respond) : this(r => Task.FromResult(respond(r))) { }

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var body = request.Content == null ? "" : await request.Content.ReadAsStringAsync(cancellationToken);
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        // The raw values, as they go on the wire (enumerating the typed headers re-joins a parsed User-Agent with commas).
        foreach (var (k, v) in request.Headers.NonValidated) headers[k] = v.ToString();
        if (request.Content != null)
        {
            foreach (var (k, v) in request.Content.Headers.NonValidated) headers[k] = v.ToString();
        }
        var seen = new SeenRequest(request.Method, request.RequestUri!, body, headers);
        Requests.Enqueue(seen);
        var response = await respond(seen);
        response.RequestMessage = request;
        return response;
    }

    public List<SeenRequest> Seen => Requests.ToList();

    public static HttpResponseMessage Json(string json, HttpStatusCode status = HttpStatusCode.OK) =>
        new(status) { Content = new StringContent(json, Encoding.UTF8, "application/json") };

    public static HttpResponseMessage Json(JsonNode json, HttpStatusCode status = HttpStatusCode.OK) => Json(json.ToJsonString(), status);

    public static HttpResponseMessage Text(string text, HttpStatusCode status = HttpStatusCode.OK) =>
        new(status) { Content = new StringContent(text, Encoding.UTF8, "text/plain") };

    public static HttpResponseMessage Status(HttpStatusCode status) => new(status) { Content = new ByteArrayContent([]) };

    /// <summary>The service worker data with a known version and visitor id.</summary>
    public static HttpResponseMessage ServiceWorker() => Text(Fixture.Text("sw_js_data.txt"));
}

/// <summary>A gate a fake response waits on, so a test can act while a request is in flight.</summary>
internal sealed class Gate
{
    readonly TaskCompletionSource _reached = new(TaskCreationOptions.RunContinuationsAsynchronously);
    readonly TaskCompletionSource _open = new(TaskCreationOptions.RunContinuationsAsynchronously);

    public Task Reached => _reached.Task;

    public async Task PassAsync()
    {
        _reached.TrySetResult();
        await _open.Task;
    }

    public void Open() => _open.TrySetResult();
}
