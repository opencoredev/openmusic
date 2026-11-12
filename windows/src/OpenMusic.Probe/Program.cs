using System.Diagnostics;
using System.Globalization;
using OpenMusic.Core;
using OpenMusic.Probe;

// openmusic-probe <provider> <command> [args]. One file per provider, like Sources/OpenMusicProbe in Swift.
if (args.Length == 0 || args[0] != "ytm")
{
    Console.WriteLine("usage: openmusic-probe ytm <command> [args]   (run 'openmusic-probe ytm' for the commands)");
    return 2;
}
var sw = Stopwatch.StartNew();
try
{
    return await YouTubeMusicProbe.RunAsync(args[1..]);
}
catch (ProviderException e)
{
    Console.WriteLine($"error ({e.Kind}): {e.Message}");
    return 1;
}
finally
{
    Console.WriteLine(string.Create(CultureInfo.InvariantCulture, $"({sw.Elapsed.TotalSeconds:0.00}s)"));
}
