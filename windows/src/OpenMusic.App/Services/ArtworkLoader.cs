using System.Runtime.InteropServices.WindowsRuntime;
using OpenMusic.Core.Mock;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.Storage.Streams;

namespace OpenMusic.App.Services;

/// <summary>
/// Loads artwork for <see cref="Image"/>s and brushes. http(s) art is downloaded, measured from its header, then decoded
/// by XAML (off the UI thread) to the size it's shown at: its short side at the requested physical pixels, never larger
/// than the file, so a 544 px cover shown at 172 px costs 172² × 4 bytes, not 544² × 4. The mock's <c>openmusic-mock://</c> URLs come from the
/// downloaded demo covers or the core's procedural renderer the same way. Two caches, both bounded by bytes: the
/// decoded images (<see cref="DecodedBudget"/>), so revisiting a page draws its art at once, and the downloaded files
/// (<see cref="EncodedBudget"/>, a few dozen KB each), so art scrolled away and evicted decodes again without the
/// network. Use from the UI thread.
/// <para>XAML: <c>&lt;Image svc:Art.Source="{x:Bind Artwork}" svc:Art.Pixels="300"/&gt;</c>.</para>
/// </summary>
public sealed class ArtworkLoader
{
    /// <summary>Decoded pixels kept after their image leaves the screen (on screen, an image stays alive anyway).</summary>
    public const long DecodedBudget = 12L << 20;
    public const long EncodedBudget = 8L << 20;
    private const int MaxFileBytes = 4 << 20;

    private static readonly HttpClient Http = new(new SocketsHttpHandler
    {
        AutomaticDecompression = System.Net.DecompressionMethods.All,
        PooledConnectionIdleTimeout = TimeSpan.FromSeconds(30),
        MaxConnectionsPerServer = 6,
    })
    { Timeout = TimeSpan.FromSeconds(20) };

    private readonly ByteLru<ImageSource> _decoded = new(DecodedBudget);
    private readonly ByteLru<byte[]> _files = new(EncodedBudget);
    private readonly Dictionary<string, Task<ImageSource?>> _pending = [];
    private readonly Dictionary<Uri, Task<byte[]?>> _downloads = [];

    public static ArtworkLoader Shared { get; } = new();

    /// <summary>Bytes of decoded art in the cache and how many images (Debug self-test <c>memory</c>).</summary>
    public (long Bytes, int Count, long FileBytes) Usage => (_decoded.Bytes, _decoded.Count, _files.Bytes);

    private static string Key(Uri url, int pixels) => $"{url}#{pixels}";

    /// <summary>The image for <paramref name="url"/> at about <paramref name="pixels"/> physical pixels, from cache when it's there.</summary>
    public ImageSource? Cached(Uri url, int pixels) => _decoded.Get(Key(url, pixels));

#if DEBUG
    private static readonly bool NoArt = OpenMusic.Core.LaunchEnvironment.Get("OPENMUSIC_NO_ART") == "1";
#endif

    public Task<ImageSource?> LoadAsync(Uri url, int pixels)
    {
#if DEBUG
        if (NoArt) return Task.FromResult<ImageSource?>(null); // memory experiments: everything but the art
#endif
        var key = Key(url, pixels);
        if (_decoded.Get(key) is { } hit) return Task.FromResult<ImageSource?>(hit);
        if (_pending.TryGetValue(key, out var running)) return running;
        var task = Load(url, pixels, key);
        // A load that finished synchronously has already run its finally; registering it now would keep it in _pending.
        if (!task.IsCompleted) _pending[key] = task;
        return task;
    }

    private async Task<ImageSource?> Load(Uri url, int pixels, string key)
    {
        try
        {
            var size = Math.Clamp(pixels, 16, 1280);
            if (MockArtwork.IsMock(url))
            {
                var bgra = await RenderBgraAsync(url, size);
                var bitmap = SoftwareBitmap.CreateCopyFromBuffer(bgra.AsBuffer(), BitmapPixelFormat.Bgra8, size, size, BitmapAlphaMode.Premultiplied);
                // SoftwareBitmapSource reads the bitmap later, when it draws: it must stay alive (disposing it crashed XAML).
                var mock = new SoftwareBitmapSource();
                await mock.SetBitmapAsync(bitmap);
                _decoded.Put(key, mock, (long)size * size * 4);
                return mock;
            }
            if (await DownloadAsync(url) is not { } file) return null;
            // The file's size comes from its header, off the UI thread; XAML then decodes it, also off the UI thread,
            // straight to that size (short side at `size`), keeping one decoded copy.
            if (await Task.Run(() => MeasureAsync(file)) is not { } dims) return null;
            var (w, h) = Fit(dims.Width, dims.Height, size);
            var image = new BitmapImage { DecodePixelType = DecodePixelType.Physical };
            if (dims.Width >= dims.Height) image.DecodePixelHeight = (int)h;
            else image.DecodePixelWidth = (int)w;
            var stream = new InMemoryRandomAccessStream();
            await stream.WriteAsync(file.AsBuffer());
            stream.Seek(0);
            await image.SetSourceAsync(stream);
            _decoded.Put(key, image, (long)w * h * 4);
            return image;
        }
        catch (Exception)
        {
            return null;
        }
        finally
        {
            _pending.Remove(key);
        }
    }

    /// <summary>The file at <paramref name="url"/>, from the cache of downloads or the network (one request per URL at a time).</summary>
    private Task<byte[]?> DownloadAsync(Uri url)
    {
        if (_files.Get(url.AbsoluteUri) is { } cached) return Task.FromResult<byte[]?>(cached);
        if (_downloads.TryGetValue(url, out var running)) return running;
        var task = Fetch(url);
        if (!task.IsCompleted) _downloads[url] = task;
        return task;

        async Task<byte[]?> Fetch(Uri u)
        {
            try
            {
                // One deadline for the headers and the body, and a body read that stops at the size limit (a chunked
                // response has no Content-Length to check first).
                using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(20));
                using var response = await Http.GetAsync(u, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
                if (!response.IsSuccessStatusCode || response.Content.Headers.ContentLength > MaxFileBytes) return null;
                await using var body = await response.Content.ReadAsStreamAsync(deadline.Token);
                using var buffer = new MemoryStream();
                var chunk = new byte[81920];
                int read;
                while ((read = await body.ReadAsync(chunk, deadline.Token)) > 0)
                {
                    if (buffer.Length + read > MaxFileBytes) return null;
                    buffer.Write(chunk, 0, read);
                }
                var bytes = buffer.ToArray();
                _files.Put(u.AbsoluteUri, bytes, bytes.Length);
                return bytes;
            }
            catch (Exception)
            {
                return null;
            }
            finally
            {
                _downloads.Remove(u);
            }
        }
    }

    /// <summary>The oriented pixel size of an image file, from its header (null when it isn't an image). Thread pool.</summary>
    private static async Task<(uint Width, uint Height)?> MeasureAsync(byte[] file)
    {
        try
        {
            using var stream = new InMemoryRandomAccessStream();
            await stream.WriteAsync(file.AsBuffer());
            stream.Seek(0);
            var decoder = await BitmapDecoder.CreateAsync(stream);
            return (decoder.OrientedPixelWidth, decoder.OrientedPixelHeight);
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>The decoded size of a <paramref name="width"/> × <paramref name="height"/> image whose short side should be
    /// <paramref name="size"/>: what a cover fill needs, and never more than the file has.</summary>
    public static (uint Width, uint Height) Fit(uint width, uint height, int size)
    {
        var scale = Math.Min(1.0, size / (double)Math.Max(1, Math.Min(width, height)));
        return ((uint)Math.Max(1, Math.Round(width * scale)), (uint)Math.Max(1, Math.Round(height * scale)));
    }

    /// <summary>Premultiplied BGRA pixels of a mock URL, mosaics and demo covers included (decoded off the UI thread).</summary>
    public static async Task<byte[]> RenderBgraAsync(Uri url, int size)
    {
        var (kind, seed) = MockArtwork.Parse(url);
        switch (kind)
        {
            case "demo" when MockArtwork.DemoFile(seed) is { } file:
                return await DecodeFileAsync(file, size) ?? await Task.Run(() => MockArtwork.RenderCover(seed, size));
            case "demo":
                return await Task.Run(() => MockArtwork.RenderCover(seed, size));
            case "mosaic":
                var keys = seed.Split('+').Take(4).ToArray();
                var half = size / 2;
                var tiles = await Task.WhenAll(keys.Select(async k =>
                    MockArtwork.DemoFile(k) is { } f && await DecodeFileAsync(f, half) is { } px ? px : await Task.Run(() => MockArtwork.RenderCover(k, half))));
                return await Task.Run(() => Compose(tiles, half, size));
            default:
                return await Task.Run(() => MockArtwork.Render(url, size));
        }
    }

    private static byte[] Compose(byte[][] tiles, int half, int size)
    {
        var output = new byte[size * size * 4];
        for (var t = 0; t < tiles.Length; t++)
        {
            int ox = t % 2 * half, oy = t / 2 * half;
            for (var y = 0; y < half; y++)
                System.Buffer.BlockCopy(tiles[t], y * half * 4, output, ((oy + y) * size + ox) * 4, half * 4);
        }
        return output;
    }

    /// <summary>Decodes a JPEG or PNG to square premultiplied BGRA (center crop), or null when it can't be read.</summary>
    public static async Task<byte[]?> DecodeFileAsync(string path, int size)
    {
        try
        {
            var file = await StorageFile.GetFileFromPathAsync(path);
            using var stream = await file.OpenReadAsync();
            var decoder = await BitmapDecoder.CreateAsync(stream);
            var scale = (double)size / Math.Min(decoder.PixelWidth, decoder.PixelHeight);
            var w = (uint)Math.Ceiling(decoder.PixelWidth * scale);
            var h = (uint)Math.Ceiling(decoder.PixelHeight * scale);
            var transform = new BitmapTransform
            {
                ScaledWidth = w, ScaledHeight = h, InterpolationMode = BitmapInterpolationMode.Fant,
                Bounds = new BitmapBounds { X = (w - (uint)size) / 2, Y = (h - (uint)size) / 2, Width = (uint)size, Height = (uint)size },
            };
            var data = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, transform,
                ExifOrientationMode.RespectExifOrientation, ColorManagementMode.ColorManageToSRgb);
            return data.DetachPixelData();
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>A PNG stream of the artwork, for the Windows media flyout (SMTC) thumbnail.</summary>
    public static async Task<RandomAccessStreamReference?> ThumbnailAsync(Uri? url)
    {
        if (url is null) return null;
        if (!MockArtwork.IsMock(url)) return RandomAccessStreamReference.CreateFromUri(url);
        var (kind, seed) = MockArtwork.Parse(url);
        if (kind == "demo" && MockArtwork.DemoFile(seed) is { } file)
            return RandomAccessStreamReference.CreateFromFile(await StorageFile.GetFileFromPathAsync(file));
        const int size = 300;
        var pixels = await RenderBgraAsync(url, size);
        var stream = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, size, size, 96, 96, pixels);
        await encoder.FlushAsync();
        stream.Seek(0);
        return RandomAccessStreamReference.CreateFromStream(stream);
    }
}

/// <summary>A least-recently-used cache whose limit is a byte budget (the newest entry always stays). UI thread only.</summary>
public sealed class ByteLru<T>(long budget) where T : class
{
    private readonly Dictionary<string, LinkedListNode<(string Key, T Value, long Bytes)>> _map = [];
    private readonly LinkedList<(string Key, T Value, long Bytes)> _order = [];

    public long Bytes { get; private set; }
    public int Count => _map.Count;

    public T? Get(string key)
    {
        if (!_map.TryGetValue(key, out var node)) return null;
        _order.Remove(node);
        _order.AddFirst(node);
        return node.Value.Value;
    }

    public void Put(string key, T value, long bytes)
    {
        if (_map.Remove(key, out var old))
        {
            _order.Remove(old);
            Bytes -= old.Value.Bytes;
        }
        _map[key] = _order.AddFirst((key, value, bytes));
        Bytes += bytes;
        while (Bytes > budget && _order.Count > 1)
        {
            var last = _order.Last!;
            _order.RemoveLast();
            _map.Remove(last.Value.Key);
            Bytes -= last.Value.Bytes;
        }
    }
}

/// <summary>
/// Artwork for a song that came without any (a song another device handed over sends only its title, artists and id):
/// the provider's own listing of it, asked once per song. Use from the UI thread.
/// </summary>
public static class TrackArtwork
{
    private const int Limit = 64;
    private static readonly Dictionary<string, Task<OpenMusic.Core.Artwork?>> Known = [];
    private static readonly Queue<string> Order = new();

    /// <summary>The track's artwork, or its listing's when it has none (null when neither is known).</summary>
    public static Task<OpenMusic.Core.Artwork?> FindAsync(OpenMusic.Core.Track track)
    {
        if (track.Artwork is { } own) return Task.FromResult<OpenMusic.Core.Artwork?>(own);
        if (App.Services.Player.Provider(track.Provider) is not { } provider || provider is OpenMusic.Core.Mock.MockProvider) return Task.FromResult<OpenMusic.Core.Artwork?>(null);
        var key = $"{track.Provider}:{track.ProviderID}";
        if (Known.TryGetValue(key, out var known)) return known;
        var task = Lookup(provider, track);
        Known[key] = task;
        Order.Enqueue(key);
        while (Order.Count > Limit) Known.Remove(Order.Dequeue());
        return task;
    }

    private static async Task<OpenMusic.Core.Artwork?> Lookup(OpenMusic.Core.IMusicProvider provider, OpenMusic.Core.Track track)
    {
        try
        {
            return (await provider.LinkedTrackAsync(track)).Artwork;
        }
        catch (Exception)
        {
            return null; // offline or not found: the placeholder stays
        }
    }
}

/// <summary>Attached properties that load artwork into an <see cref="Image"/> or an <see cref="ImageBrush"/>.</summary>
public static class Art
{
    public static readonly DependencyProperty SourceProperty = DependencyProperty.RegisterAttached(
        "Source", typeof(Uri), typeof(Art), new PropertyMetadata(null, OnChanged));

    public static readonly DependencyProperty PixelsProperty = DependencyProperty.RegisterAttached(
        "Pixels", typeof(int), typeof(Art), new PropertyMetadata(300, OnChanged));

    public static Uri? GetSource(DependencyObject d) => (Uri?)d.GetValue(SourceProperty);
    public static void SetSource(DependencyObject d, Uri? value) => d.SetValue(SourceProperty, value);
    public static int GetPixels(DependencyObject d) => (int)d.GetValue(PixelsProperty);
    public static void SetPixels(DependencyObject d, int value) => d.SetValue(PixelsProperty, value);

    /// <summary>The scale <see cref="Pixels"/> is multiplied by for a brush, which has no XamlRoot of its own
    /// (<see cref="Controls.ArtworkView"/> sets it from its own). Images use their XamlRoot's.</summary>
    public static readonly DependencyProperty ScaleProperty = DependencyProperty.RegisterAttached(
        "Scale", typeof(double), typeof(Art), new PropertyMetadata(0.0, OnChanged));

    public static double GetScale(DependencyObject d) => (double)d.GetValue(ScaleProperty);
    public static void SetScale(DependencyObject d, double value) => d.SetValue(ScaleProperty, value);

    private static readonly DependencyProperty ShownProperty = DependencyProperty.RegisterAttached(
        "Shown", typeof(Uri), typeof(Art), new PropertyMetadata(null));

    private static bool _batching;

    /// <summary>Sets the three at once: one load, at the final size.</summary>
    public static void Set(DependencyObject d, Uri? url, int pixels, double scale)
    {
        _batching = true;
        try
        {
            SetScale(d, scale);
            SetPixels(d, pixels);
            SetSource(d, url);
        }
        finally
        {
            _batching = false;
        }
        Refresh(d);
    }

    private static void OnChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (!_batching) Refresh(d);
    }

    /// <summary>The physical size <paramref name="d"/> asks for.</summary>
    public static int RequestedPixels(DependencyObject d) =>
        Bucket(GetPixels(d) * (GetScale(d) is > 0 and var s ? s : (d as UIElement)?.XamlRoot?.RasterizationScale ?? 1.0));

    private static async void Refresh(DependencyObject d)
    {
        var url = GetSource(d);
        if (url is null)
        {
            d.SetValue(ShownProperty, null);
            Apply(d, null);
            return;
        }
        var pixels = RequestedPixels(d);
        // Cached art goes in synchronously: no flash of the placeholder when a page or row comes back.
        if (ArtworkLoader.Shared.Cached(url, pixels) is { } hit)
        {
            d.SetValue(ShownProperty, url);
            Apply(d, hit);
            return;
        }
        // The same art at another size keeps showing until the new size is ready.
        if (!Equals(d.GetValue(ShownProperty), url)) Apply(d, null);
        var source = await ArtworkLoader.Shared.LoadAsync(url, pixels);
        if (GetSource(d) != url || RequestedPixels(d) != pixels || source is null) return;
        d.SetValue(ShownProperty, url);
        Apply(d, source);
    }

    /// <summary>Physical pixels rounded up to a few sizes, so rows and cards of nearly the same size share cache entries.</summary>
    public static int Bucket(double physical)
    {
        var px = (int)Math.Ceiling(physical);
        var step = px <= 256 ? 32 : px <= 512 ? 64 : 128;
        return Math.Clamp((px + step - 1) / step * step, 32, 1280);
    }

    private static void Apply(DependencyObject d, ImageSource? source)
    {
        switch (d)
        {
            case Image image: image.Source = source; break;
            case ImageBrush brush: brush.ImageSource = source; break;
        }
    }
}
