using System.Runtime.InteropServices.WindowsRuntime;
using OpenMusic.App.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace OpenMusic.App.Services;

/// <summary>
/// <c>--snapshot &lt;dir&gt;</c>: opens each main screen in the real window at 1440x900, in light and dark, saves PNGs
/// (<c>light-home.png</c>, <c>dark-album.png</c>, …, <c>light-mini.png</c>) and quits. The window's XAML is rendered with
/// RenderTargetBitmap over the Mica Alt base color (RenderTargetBitmap can't see the backdrop itself), so the images
/// match what's on screen without depending on the screen's size. Exit code 0 when every screen was written.
/// </summary>
public sealed class Snapshotter(MainWindow window, string directory)
{
    private static readonly string[] Screens = ["home", "new", "album", "artist", "playlist", "search", "songs", "albums", "lyrics", "queue", "nowplaying", "settings"];

    public async Task RunAsync()
    {
        var written = 0;
        try
        {
            Directory.CreateDirectory(directory);
            window.ResizeClient(1440, 900);
            await Settle(1500);
            foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
            {
                window.SetTheme(theme);
                var name = theme == ElementTheme.Dark ? "dark" : "light";
                foreach (var screen in Screens)
                {
                    await Show(screen);
                    await Save(window.Shell, Path.Combine(directory, $"{name}-{screen}.png"), 1440, 900, theme);
                    written++;
                }
                window.ShowMiniPlayer();
                if (window.MiniPlayer is { } mini)
                {
                    await Settle(900);
                    await Save(mini.View, Path.Combine(directory, $"{name}-mini.png"), 320, 320, ElementTheme.Dark);
                    written++;
                    mini.Close();
                }
            }
            Log.Info($"snapshot: wrote {written} images to {directory}");
        }
        catch (Exception e)
        {
            Log.Error("snapshot failed", e);
            Environment.ExitCode = 1;
        }
        Application.Current.Exit();
    }

    private async Task Show(string screen)
    {
        var shell = window.Shell;
        shell.ShowPane(null);
        shell.ShowNowPlaying(false);
        shell.ClearSearch();
        switch (screen)
        {
            case "lyrics":
                await shell.OpenScreenAsync("album");
                shell.ShowPane(SidePaneTab.Lyrics);
                break;
            case "queue":
                await shell.OpenScreenAsync("album");
                shell.ShowPane(SidePaneTab.UpNext);
                break;
            default:
                await shell.OpenScreenAsync(screen);
                break;
        }
        await Settle(1200);
    }

    /// <summary>Waits for layout, data and artwork: a fixed pause, then two idle dispatcher turns.</summary>
    private static async Task Settle(int milliseconds)
    {
        await Task.Delay(milliseconds);
        for (var i = 0; i < 2; i++)
        {
            var done = new TaskCompletionSource();
            App.Services.Dispatcher.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => done.SetResult());
            await done.Task;
        }
    }

    private static async Task Save(UIElement element, string path, int width, int height, ElementTheme theme)
    {
        var rtb = new RenderTargetBitmap();
        await rtb.RenderAsync(element, width, height);
        var pixels = (await rtb.GetPixelsAsync()).ToArray();
        int w = rtb.PixelWidth, h = rtb.PixelHeight;
        // Composite over the backdrop's base color, as Mica Alt shows it behind transparent areas.
        var (r, g, b) = theme == ElementTheme.Dark ? (0x20, 0x20, 0x24) : (0xEE, 0xF0, 0xF3);
        for (var i = 0; i < pixels.Length; i += 4)
        {
            var a = pixels[i + 3];
            if (a == 255) continue;
            var inv = 255 - a;
            pixels[i] = (byte)(pixels[i] + b * inv / 255);
            pixels[i + 1] = (byte)(pixels[i + 1] + g * inv / 255);
            pixels[i + 2] = (byte)(pixels[i + 2] + r * inv / 255);
            pixels[i + 3] = 255;
        }
        using var stream = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)w, (uint)h, 96, 96, pixels);
        await encoder.FlushAsync();
        stream.Seek(0);
        var read = await stream.ReadAsync(new Windows.Storage.Streams.Buffer((uint)stream.Size), (uint)stream.Size, InputStreamOptions.None);
        await File.WriteAllBytesAsync(path, read.ToArray());
        Log.Info($"snapshot: {Path.GetFileName(path)} {w}x{h}");
    }
}
