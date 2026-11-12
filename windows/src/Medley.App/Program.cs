using Medley.App.Services;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace Medley.App;

/// <summary>
/// The entry point (XAML's generated Main is off): one OpenMusic at a time. A second launch, and an <c>openmusic://</c> link the
/// browser opens (the Google sign-in coming back), is handed to the running instance, which brings its window forward.
/// Demo and snapshot runs don't take part, so they can run beside a normal one.
/// </summary>
public static class Program
{
    public const string InstanceKey = "OpenMusic.Main";

    [STAThread]
    public static int Main(string[] args)
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();
        var isolated = args.Any(a => a is "--demo" or "--snapshot");
        if (!isolated)
        {
            var main = AppInstance.FindOrRegisterForKey(InstanceKey);
            if (!main.IsCurrent)
            {
                var activation = AppInstance.GetCurrent().GetActivatedEventArgs();
                // Off the STA thread: redirecting waits on a cross-process call.
                Task.Run(() => main.RedirectActivationToAsync(activation).AsTask()).Wait(TimeSpan.FromSeconds(10));
                return 0;
            }
            main.Activated += (_, e) => App.OnRedirected(e);
        }
        Application.Start(callback =>
        {
            var context = new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            new App();
        });
        return 0;
    }

    /// <summary>Registers <c>openmusic:</c> for this user (HKCU) to open this exe, so the browser can hand sign-ins back.</summary>
    public static void RegisterUrlScheme()
    {
        try
        {
            var exe = Environment.ProcessPath;
            if (exe is null) return;
            using var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey($@"Software\Classes\{Medley.Core.ProductInfo.UrlScheme}");
            var command = $"\"{exe}\" \"%1\"";
            using var open = key.CreateSubKey(@"shell\open\command");
            if (open.GetValue(null) as string == command) return;
            key.SetValue(null, $"URL:{Medley.Core.ProductInfo.Name}");
            key.SetValue("URL Protocol", "");
            using (var icon = key.CreateSubKey("DefaultIcon")) icon.SetValue(null, $"\"{exe}\",0");
            open.SetValue(null, command);
            Log.Info($"registered the {Medley.Core.ProductInfo.UrlScheme}: URL scheme for this user");
        }
        catch (Exception e)
        {
            Log.Error($"couldn't register the {Medley.Core.ProductInfo.UrlScheme}: URL scheme: {e.GetType().Name}");
        }
    }
}
