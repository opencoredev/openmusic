using System.Diagnostics;
using OpenMusic.App.Services;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace OpenMusic.App;

public partial class App : Application
{
    private MainWindow? _window;
    private static DispatcherQueue? _dispatcher;
    private static readonly Stopwatch Launch = Stopwatch.StartNew();
    private static readonly List<Uri> Pending = [];

    /// <summary>The app's services, created in <see cref="OnLaunched"/> on the UI thread.</summary>
    public static AppServices Services { get; private set; } = null!;

    public static MainWindow? MainWindow => (Current as App)?._window;

    /// <summary>Milliseconds since the process started, for launch timings in the log.</summary>
    public static double SinceLaunch => Launch.Elapsed.TotalMilliseconds;

    [ThreadStatic] private static bool _tracing;

    public App()
    {
        Interop.AppIdentity.Apply();
        InitializeComponent();
        UnhandledException += (_, e) =>
        {
            Log.Error("unhandled", e.Exception);
            e.Handled = Services?.Options.IsSnapshot != true;
        };
        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            Log.Error("unobserved task", e.Exception);
            e.SetObserved();
        };
        // OPENMUSIC_TRACE_EXCEPTIONS=1: every first-chance exception's type and first line go to the log (redacted like
        // every line), for failures that are caught and swallowed somewhere, such as inside WinRT callbacks.
        if (OpenMusic.Core.LaunchEnvironment.Get("OPENMUSIC_TRACE_EXCEPTIONS") == "1")
        {
            AppDomain.CurrentDomain.FirstChanceException += (_, e) =>
            {
                if (e.Exception is OperationCanceledException || _tracing) return;
                _tracing = true; // logging can throw (and catch) too
                try
                {
                    var line = e.Exception.Message.Split('\n', 2)[0];
                    Log.Info($"first-chance {e.Exception.GetType().FullName}: {(line.Length > 300 ? line[..300] : line)}");
                }
                finally { _tracing = false; }
            };
        }
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        var options = AppOptions.Parse(Environment.GetCommandLineArgs().Skip(1).ToList());
        Log.Info($"launch {(options.IsDemo ? "demo" : "live")} {string.Join(' ', Environment.GetCommandLineArgs().Skip(1).Where(a => !a.StartsWith(OpenMusic.Core.ProductInfo.UrlScheme + ":", StringComparison.OrdinalIgnoreCase)))}");
        _dispatcher = DispatcherQueue.GetForCurrentThread();
        Services = new AppServices(options, _dispatcher);
        if (!options.IsDemo) Program.RegisterUrlScheme();
        await Services.StartAsync();
        Log.Info($"timing: services ready at {SinceLaunch:F0} ms");
        _window = new MainWindow();
        _window.Activate();
        Log.Info($"timing: window shown at {SinceLaunch:F0} ms");
        List<Uri> early;
        lock (Pending)
        {
            early = [.. Pending];
            Pending.Clear();
        }
        foreach (var link in early) _window.Shell.HandleLink(link);
        if (options.IsSnapshot) await new Snapshotter(_window, options.SnapshotDirectory!).RunAsync();
#if DEBUG
        if (options.SelfTestFile is { } file) _ = SelfTest.RunAsync(file);
#endif
    }

    /// <summary>A second launch or an <c>openmusic://</c> link went to this instance: bring the window up and handle the link.
    /// Arrives on a worker thread.</summary>
    public static void OnRedirected(AppActivationArguments activation)
    {
        Uri? link = null;
        if (activation.Kind == ExtendedActivationKind.Protocol && activation.Data is Windows.ApplicationModel.Activation.IProtocolActivatedEventArgs protocol)
            link = protocol.Uri;
        else if (activation.Data is Windows.ApplicationModel.Activation.ILaunchActivatedEventArgs launch)
            link = launch.Arguments.Split(' ', StringSplitOptions.RemoveEmptyEntries).Select(a => a.Trim('"'))
                .Where(a => a.StartsWith(OpenMusic.Core.ProductInfo.UrlScheme + ":", StringComparison.OrdinalIgnoreCase))
                .Select(a => Uri.TryCreate(a, UriKind.Absolute, out var u) ? u : null).FirstOrDefault(u => u is not null);
        lock (Pending)
        {
            if (_dispatcher is null || MainWindow is null)
            {
                // Still starting: OnLaunched hands these over once the window is up.
                if (link is not null) Pending.Add(link);
                return;
            }
        }
        _dispatcher.TryEnqueue(() =>
        {
            MainWindow?.BringToFront();
            if (link is not null) MainWindow?.Shell.HandleLink(link);
        });
    }
}
