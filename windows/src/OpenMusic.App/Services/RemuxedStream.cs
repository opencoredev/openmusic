using OpenMusic.Providers.YouTube.Playback;

namespace OpenMusic.App.Services;

/// <summary>
/// The flat-MP4 view (<see cref="FragmentedMp4"/>) of a fragmented MP4 at an HTTP URL, as a seekable stream: the new
/// header comes from memory, every other byte from the original file through an <see cref="HttpRangeStream"/>. Media
/// Foundation plays and seeks it like any MP4.
/// </summary>
public sealed class RemuxedStream(FragmentedMp4.Layout layout, HttpRangeStream source) : Stream
{
    private long _position;

    public FragmentedMp4.Layout Layout => layout;

    /// <summary>
    /// Opens <paramref name="url"/> and returns its flat view, or null when it isn't a fragmented MP4 with an index (then
    /// play it as it is). Reads the head and every fragment's moof (a few kB each, eight at a time) before returning.
    /// </summary>
    public static async Task<RemuxedStream?> OpenAsync(Uri url, IReadOnlyDictionary<string, string> headers, CancellationToken ct)
    {
        var head = await HttpRangeStream.FetchAsync(url, headers, 0, 64 * 1024, ct).ConfigureAwait(false);
        var parsed = FragmentedMp4.ParseHead(head, out var needed);
        if (parsed is null && needed > head.Length && needed < 4 * 1024 * 1024)
        {
            head = await HttpRangeStream.FetchAsync(url, headers, 0, (int)needed, ct).ConfigureAwait(false);
            parsed = FragmentedMp4.ParseHead(head, out _);
        }
        if (parsed is null) return null;
        var defaults = FragmentedMp4.Defaults(parsed);
        var fragments = new FragmentedMp4.Fragment[parsed.Fragments.Count];
        using var gate = new SemaphoreSlim(8);
        await Task.WhenAll(parsed.Fragments.Select(async (r, i) =>
        {
            await gate.WaitAsync(ct).ConfigureAwait(false);
            try
            {
                // The moof is near the fragment's start; the head's own bytes may already hold it.
                var bytes = r.Offset + 4096 <= head.Length
                    ? head.AsMemory((int)r.Offset, 4096).ToArray()
                    : await HttpRangeStream.FetchAsync(url, headers, r.Offset, (int)Math.Min(4096, r.Size), ct).ConfigureAwait(false);
                var fragment = FragmentedMp4.ParseMoof(bytes, r.Offset, defaults, out var more);
                if (fragment is null && more > 0)
                {
                    bytes = await HttpRangeStream.FetchAsync(url, headers, r.Offset, more, ct).ConfigureAwait(false);
                    fragment = FragmentedMp4.ParseMoof(bytes, r.Offset, defaults, out _);
                }
                fragments[i] = fragment ?? throw new FormatException($"fragment {i} has no complete moof");
            }
            finally
            {
                gate.Release();
            }
        })).ConfigureAwait(false);
        var layout = FragmentedMp4.Build(parsed, fragments);
        return new RemuxedStream(layout, HttpRangeStream.Unopened(url, headers, parsed.Fragments[^1].Offset + parsed.Fragments[^1].Size, "audio/mp4"));
    }

    /// <summary>A second reader of the same flat file (Media Foundation clones its byte stream).</summary>
    public RemuxedStream Clone() => new(layout, source.Clone());

    public override bool CanRead => true;
    public override bool CanSeek => true;
    public override bool CanWrite => false;
    public override long Length => layout.Length;

    public override long Position
    {
        get => _position;
        set => _position = Math.Clamp(value, 0, layout.Length);
    }

    public override long Seek(long offset, SeekOrigin origin) => Position = origin switch
    {
        SeekOrigin.Begin => offset,
        SeekOrigin.Current => _position + offset,
        _ => layout.Length + offset,
    };

    public override int Read(byte[] buffer, int offset, int count) =>
        ReadAsync(buffer.AsMemory(offset, count), CancellationToken.None).AsTask().GetAwaiter().GetResult();

    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
        ReadAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();

    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
    {
        if (buffer.Length == 0 || _position >= layout.Length) return 0;
        var header = layout.Header;
        if (_position < header.Length)
        {
            var n = (int)Math.Min(buffer.Length, header.Length - _position);
            header.AsMemory((int)_position, n).CopyTo(buffer);
            _position += n;
            return n;
        }
        var index = layout.SegmentIndex(_position);
        if (index < 0) return 0;
        var segment = layout.Segments[index];
        var within = _position - segment.FlatOffset;
        var want = (int)Math.Min(buffer.Length, segment.Length - within);
        source.Position = segment.SourceOffset + within;
        var read = await source.ReadAsync(buffer[..want], cancellationToken).ConfigureAwait(false);
        _position += read;
        return read;
    }

    public override void Flush() { }
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

    protected override void Dispose(bool disposing)
    {
        if (disposing) source.Dispose();
        base.Dispose(disposing);
    }
}
