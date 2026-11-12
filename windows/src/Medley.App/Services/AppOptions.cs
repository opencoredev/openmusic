using System.Globalization;
using Medley.Core.Mock;

namespace Medley.App.Services;

/// <summary>
/// Command-line switches. Without <c>--demo</c> (or <c>--snapshot</c>) the app runs on YouTube Music with sync.
/// <code>
///   --demo                   the mock catalog (no network, sign-in or sync), for screenshots
///   --snapshot &lt;dir&gt;        open each main screen at 1440x900 in light and dark, save PNGs, exit
///   --dataset demo|sample    mock catalog (default demo: real chart albums, made-up listener)
///   --demo-art &lt;dir&gt;        downloaded demo covers (scripts/demo-art.sh); default MEDLEY_DEMO_ART or %LOCALAPPDATA%\Medley\demo-art
///   --screen &lt;name&gt;         open on home|new|radio|album|artist|playlist|search|songs|albums|artists|liked|recent|nowplaying|devices|settings
///   --pane lyrics|queue      open the right pane
///   --mini                   open the mini player too
///   --play                   start the demo song (paused at 1:12 otherwise)
///   --position &lt;seconds&gt;     where the demo song starts (default 72)
///   --theme light|dark       app theme (default: system)
///   --size WxH               window client size in pixels
///   --mock-audio-url &lt;url&gt;  play this URL for every mock song instead of the generated tone
///   --no-restore             don't restore or save the queue
///   --onboarding             show the first run even when it was finished before
///   --test-sign-ins          Debug builds only: accept the sync probe's fake YouTube sign-ins (live sync tests)
///   --device-name &lt;name&gt;   the name this PC shows to your other devices, for this run
///   --self-test &lt;file&gt;      Debug builds only: run the steps in this file (UI automation helpers), log to the app log
/// </code>
/// </summary>
public sealed class AppOptions
{
    public string? SnapshotDirectory { get; private set; }
    public MockDataset Dataset { get; private set; } = MockDataset.Demo;
    public string? DemoArtDirectory { get; private set; }
    public string? Screen { get; private set; }
    public string? Pane { get; private set; }
    public bool Mini { get; private set; }
    public bool Play { get; private set; }
    public double? Position { get; private set; }
    public string? Theme { get; private set; }
    public (int Width, int Height)? Size { get; private set; }
    public Uri? MockAudioUrl { get; private set; }
    public bool NoRestore { get; private set; }
    public bool Demo { get; private set; }
    public bool TestSignIns { get; private set; }
    /// <summary>Show the first run even when it was done (it changes nothing it hasn't changed before).</summary>
    public bool Onboarding { get; private set; }
    /// <summary><c>--demo-sync</c> with <c>--demo</c>: made-up devices in the Devices flyout and a Continue InfoBar, for
    /// screenshots of the sync UI without a second device.</summary>
    public bool DemoSync { get; private set; }
    public string? DeviceName { get; private set; }
    public string? SelfTestFile { get; private set; }
    /// <summary>A <c>medley://</c> link the app was started with (sign-in callbacks).</summary>
    public Uri? Link { get; private set; }

    /// <summary>The mock catalog: <c>--demo</c>, and always for snapshots.</summary>
    public bool IsDemo => Demo || IsSnapshot;

    public bool IsSnapshot => SnapshotDirectory is not null;

    public static AppOptions Parse(IReadOnlyList<string> args)
    {
        var o = new AppOptions();
        for (var i = 0; i < args.Count; i++)
        {
            string Next() => i + 1 < args.Count ? args[++i] : "";
            switch (args[i])
            {
                case "--snapshot": o.SnapshotDirectory = Path.GetFullPath(Next()); break;
                case "--dataset": o.Dataset = Next() == "sample" ? MockDataset.Sample : MockDataset.Demo; break;
                case "--demo-art": o.DemoArtDirectory = Path.GetFullPath(Next()); break;
                case "--screen": o.Screen = Next(); break;
                case "--pane": o.Pane = Next(); break;
                case "--mini": o.Mini = true; break;
                case "--play": o.Play = true; break;
                case "--position": o.Position = double.TryParse(Next(), NumberStyles.Float, CultureInfo.InvariantCulture, out var pos) ? pos : null; break;
                case "--theme": o.Theme = Next(); break;
                case "--size":
                    var parts = Next().Split('x');
                    if (parts.Length == 2 && int.TryParse(parts[0], CultureInfo.InvariantCulture, out var w) && int.TryParse(parts[1], CultureInfo.InvariantCulture, out var h))
                        o.Size = (w, h);
                    break;
                case "--mock-audio-url": o.MockAudioUrl = Uri.TryCreate(Next(), UriKind.Absolute, out var u) ? u : null; break;
                case "--no-restore": o.NoRestore = true; break;
                case "--demo": o.Demo = true; break;
                case "--demo-sync": o.DemoSync = true; break;
                case "--device-name": o.DeviceName = Next(); break;
                case "--onboarding": o.Onboarding = true; break;
#if DEBUG
                case "--test-sign-ins": o.TestSignIns = true; break;
                case "--self-test": o.SelfTestFile = Path.GetFullPath(Next()); break;
#endif
                default:
                    if (args[i].StartsWith(Medley.Core.ProductInfo.UrlScheme + ":", StringComparison.OrdinalIgnoreCase) && Uri.TryCreate(args[i], UriKind.Absolute, out var link)) o.Link = link;
                    break;
            }
        }
        o.DemoArtDirectory ??= Environment.GetEnvironmentVariable("MEDLEY_DEMO_ART") is { Length: > 0 } env ? env : DefaultDemoArt();
        if (o.IsSnapshot) o.NoRestore = true;
        return o;
    }

    private static string? DefaultDemoArt()
    {
        foreach (var dir in new[]
        {
            Path.Combine(AppContext.BaseDirectory, "demo-art"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), Medley.Core.ProductInfo.FolderName, "demo-art"),
        })
        {
            if (Directory.Exists(dir)) return dir;
        }
        return null;
    }
}
