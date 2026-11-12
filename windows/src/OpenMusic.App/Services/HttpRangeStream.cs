using System.Net;
using System.Net.Http.Headers;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Foundation;
using Windows.Storage.Streams;

namespace OpenMusic.App.Services;

/// <summary>
/// A seekable read-only stream over an HTTP URL that takes byte ranges, sending the headers the URL needs on every
/// request (YouTube's stream URLs are only served with the User-Agent of the client that asked for them, which
/// <c>MediaSource.CreateFromUri</c> can't set). MediaPlayer reads it through <c>AsRandomAccessStream()</c>.
/// <para>Reads go through one open response while they are sequential; a seek opens a new range there. Ranges are asked
/// for in <see cref="ChunkSize"/> pieces, as YouTube throttles open-ended requests.</para>
/// </summary>
public sealed class HttpRangeStream : Stream
{
    public const long ChunkSize = 4 * 1024 * 1024;

    private static readonly HttpClient Http = new(new SocketsHttpHandler
    {
        AutomaticDecompression = DecompressionMethods.None,
        PooledConnectionLifetime = TimeSpan.FromMinutes(5),
        ConnectTimeout = TimeSpan.FromSeconds(15),
    })
    { Timeout = Timeout.InfiniteTimeSpan };

    private readonly Uri _url;
    private readonly IReadOnlyDictionary<string, string> _headers;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private HttpResponseMessage? _response;
    private Stream? _body;
    /// <summary>Where <see cref="_body"/> is, and where its range ends (exclusive).</summary>
    private long _bodyPosition, _bodyEnd;
    private long _position;
    private bool _disposed;

    private HttpRangeStream(Uri url, IReadOnlyDictionary<string, string> headers, long length, string? contentType)
    {
        _url = url;
        _headers = headers;
        Length = length;
        ContentType = contentType;
    }

    public string? ContentType { get; }

    /// <summary>A second reader of the same URL (Media Foundation clones the stream it was given). Opens on its first read.</summary>
    public HttpRangeStream Clone() => new(_url, _headers, Length, ContentType);

    /// <summary>A reader of a URL whose length is already known; it opens on its first read.</summary>
    public static HttpRangeStream Unopened(Uri url, IReadOnlyDictionary<string, string> headers, long length, string? contentType) =>
        new(url, headers, length, contentType);

    /// <summary>Bytes <paramref name="from"/> to <paramref name="from"/>+<paramref name="count"/> (fewer at the end).</summary>
    public static async Task<byte[]> FetchAsync(Uri url, IReadOnlyDictionary<string, string> headers, long from, int count, CancellationToken ct)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        foreach (var (name, value) in headers) request.Headers.TryAddWithoutValidation(name, value);
        request.Headers.Range = new RangeHeaderValue(from, from + count - 1);
        using var response = await Http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
        if (response.StatusCode is not (HttpStatusCode.PartialContent or HttpStatusCode.OK))
            throw new HttpRequestException($"The stream answered {(int)response.StatusCode}.", null, response.StatusCode);
        var bytes = await response.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
        // A server that ignored the range sent the whole file from 0.
        if (response.StatusCode == HttpStatusCode.OK && from > 0) bytes = bytes.AsSpan((int)Math.Min(from, bytes.Length)).ToArray();
        return bytes.Length > count ? bytes[..count] : bytes;
    }

    /// <summary>Opens the URL with a first range, which gives the length, and keeps that response for the first reads.</summary>
    public static async Task<HttpRangeStream> OpenAsync(Uri url, IReadOnlyDictionary<string, string> headers, CancellationToken ct)
    {
        var (response, start, end, total) = await RequestAsync(url, headers, 0, ct).ConfigureAwait(false);
        var stream = new HttpRangeStream(url, headers, total, response.Content.Headers.ContentType?.MediaType);
        stream._response = response;
        stream._body = await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
        stream._bodyPosition = start;
        stream._bodyEnd = end;
        return stream;
    }

    private static async Task<(HttpResponseMessage Response, long Start, long End, long Total)> RequestAsync(
        Uri url, IReadOnlyDictionary<string, string> headers, long from, CancellationToken ct)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        foreach (var (name, value) in headers) request.Headers.TryAddWithoutValidation(name, value);
        request.Headers.Range = new RangeHeaderValue(from, from + ChunkSize - 1);
        var response = await Http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
        if (response.StatusCode == HttpStatusCode.PartialContent && response.Content.Headers.ContentRange is { } range)
        {
            var total = range.Length ?? throw new IOException("The stream's length is unknown.");
            return (response, range.From ?? from, (range.To ?? total - 1) + 1, total);
        }
        if (response.StatusCode == HttpStatusCode.OK && from == 0 && response.Content.Headers.ContentLength is { } length)
            return (response, 0, length, length);
        var status = (int)response.StatusCode;
        response.Dispose();
        throw new HttpRequestException($"The stream answered {status}.", null, response.StatusCode);
    }

    public override long Length { get; }
    public override bool CanRead => true;
    public override bool CanSeek => true;
    public override bool CanWrite => false;

    public override long Position
    {
        get => _position;
        set => _position = Math.Clamp(value, 0, Length);
    }

    public override long Seek(long offset, SeekOrigin origin) => Position = origin switch
    {
        SeekOrigin.Begin => offset,
        SeekOrigin.Current => _position + offset,
        _ => Length + offset,
    };

    public override int Read(byte[] buffer, int offset, int count) =>
        ReadAsync(buffer.AsMemory(offset, count), CancellationToken.None).AsTask().GetAwaiter().GetResult();

    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
        ReadAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();

    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
    {
        if (buffer.Length == 0 || _position >= Length) return 0;
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            for (var attempt = 0; ; attempt++)
            {
                try
                {
                    if (_body is null || _bodyPosition != _position || _bodyPosition >= _bodyEnd) await ReopenAsync(cancellationToken).ConfigureAwait(false);
                    var want = (int)Math.Min(buffer.Length, _bodyEnd - _bodyPosition);
                    var read = await _body!.ReadAsync(buffer[..want], cancellationToken).ConfigureAwait(false);
                    if (read == 0) throw new IOException("The stream ended early.");
                    _bodyPosition += read;
                    _position += read;
                    return read;
                }
                catch (Exception e) when (attempt < 2 && e is IOException or HttpRequestException && !cancellationToken.IsCancellationRequested)
                {
                    // A dropped connection: open the range again where we are.
                    CloseBody();
                }
            }
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task ReopenAsync(CancellationToken ct)
    {
        CloseBody();
        var (response, start, end, _) = await RequestAsync(_url, _headers, _position, ct).ConfigureAwait(false);
        _response = response;
        _body = await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
        _bodyPosition = start;
        _bodyEnd = end;
    }

    private void CloseBody()
    {
        _body?.Dispose();
        _response?.Dispose();
        _body = null;
        _response = null;
    }

    public override void Flush() { }
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

    protected override void Dispose(bool disposing)
    {
        if (disposing && !_disposed)
        {
            _disposed = true;
            CloseBody();
        }
        base.Dispose(disposing);
    }
}

/// <summary>
/// <see cref="HttpRangeStream"/> as a WinRT <see cref="IRandomAccessStreamWithContentType"/> for
/// <c>MediaSource.CreateFromStream</c>. .NET's own adapter can't clone, and Media Foundation clones the byte stream it
/// is given, so playback failed with E_NOTIMPL; each clone here is an independent reader of the same URL.
/// </summary>
public sealed partial class HttpRandomAccessStream(Stream stream, string contentType) : IRandomAccessStreamWithContentType
{
    private Stream Copy() => stream switch
    {
        HttpRangeStream http => http.Clone(),
        RemuxedStream remux => remux.Clone(),
        _ => throw new NotSupportedException(),
    };

    public string ContentType { get; } = contentType;
    public bool CanRead => true;
    public bool CanWrite => false;
    public ulong Position => (ulong)stream.Position;

    public ulong Size
    {
        get => (ulong)stream.Length;
        set => throw new NotSupportedException();
    }

    public IRandomAccessStream CloneStream() => new HttpRandomAccessStream(Copy(), ContentType);

    public IInputStream GetInputStreamAt(ulong position)
    {
        var clone = (HttpRandomAccessStream)CloneStream();
        clone.Seek(position);
        return clone;
    }

    public IOutputStream GetOutputStreamAt(ulong position) => throw new NotSupportedException();

    public void Seek(ulong position) => stream.Position = (long)Math.Min(position, (ulong)stream.Length);

    public IAsyncOperationWithProgress<IBuffer, uint> ReadAsync(IBuffer buffer, uint count, InputStreamOptions options) =>
        AsyncInfo.Run<IBuffer, uint>(async (token, progress) =>
        {
            var want = (int)Math.Min(count, buffer.Capacity);
            var bytes = new byte[want];
            var filled = 0;
            // Fill the request unless the caller takes a partial read (or the stream ends).
            while (filled < want)
            {
                var read = await stream.ReadAsync(bytes.AsMemory(filled, want - filled), token).ConfigureAwait(false);
                if (read == 0) break;
                filled += read;
                if (options.HasFlag(InputStreamOptions.Partial)) break;
            }
            // A buffer of our own: the caller's may not give byte access to managed code.
            return bytes.AsBuffer(0, filled);
        });

    public IAsyncOperationWithProgress<uint, uint> WriteAsync(IBuffer buffer) => throw new NotSupportedException();

    public IAsyncOperation<bool> FlushAsync() => AsyncInfo.Run(_ => Task.FromResult(true));

    public void Dispose() => stream.Dispose();
}
