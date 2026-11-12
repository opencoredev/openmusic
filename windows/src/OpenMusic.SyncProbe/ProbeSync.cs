using System.Diagnostics;
using System.Text;
using OpenMusic.Core;
using OpenMusic.Core.Mock;
using OpenMusic.Core.Sync;
using OpenMusic.Core.Threading;
using OpenMusic.Sync;
using OpenMusic.Sync.Account;
using OpenMusic.Sync.Convex;
using OpenMusic.Sync.Keys;

namespace OpenMusic.SyncProbe;

public static partial class Probe
{
    /// <summary>A fake provider sign-in: text in memory, so a key exchange can be proven by one opening on the other device.</summary>
    private sealed class ProbeSignIn(ProviderId provider) : ISignInTransfer
    {
        public ProviderId Provider { get; } = provider;
        public byte[]? Data { get; set; }
        public Action? SignInDidChange { get; set; }
        public Task<byte[]?> ExportSignInAsync() => Task.FromResult(Data);
        public Task ImportSignInAsync(byte[] data) { Data = data; return Task.CompletedTask; }
        public Task SignOutAsync() { Data = null; return Task.CompletedTask; }
        public string Text => Data is null ? "(signed out)" : Encoding.UTF8.GetString(Data);
    }

    private static Task<int> SyncCommand(string command, Options options)
    {
        var result = 0;
        MainThreadContext.Run(async () => { result = await RunSync(command, options); });
        return Task.FromResult(result);
    }

    private static async Task<int> RunSync(string command, Options options)
    {
        var actor = new SyncActor(SynchronizationContext.Current!);
        var store = new SyncCredentialStore(new FileSecretStore(options.State));
        var url = options.Value("--url") is { } u ? new Uri(u) : DevDeployment;
        var clerk = await SignedInClerk(options, store);
        var user = clerk.SavedUser ?? throw new InvalidOperationException("not signed in to Clerk");
        // --platform ios|mac|windows: the platform the probe registers as (the apps pick the device's icon from it).
        var platform = options.Value("--platform") switch { "ios" => DevicePlatform.Ios, "mac" => DevicePlatform.Mac, _ => DevicePlatform.Windows };
        var info = new DeviceInfo(Name, platform, "openmusic-sync-probe (Windows C#)", OpenMusicSyncInfo.Version);
        var service = new SyncService(url, info, store, actor);
        var sw = Stopwatch.StartNew();
        await service.SignInAsync(clerk, user.Id);
        Log($"sync: signed in and registered as {service.SelfId} in {sw.ElapsedMilliseconds} ms (token saved, not shown); key {Describe(service.KeyStatus)}");
        await WaitFor(() => service.Devices.Count > 0 && service.Clock.HasSample, TimeSpan.FromSeconds(20), "the device list");
        Log($"sync: device list after {sw.ElapsedMilliseconds} ms; clock offset {service.Clock.OffsetMs:F0} ms");
        try
        {
            switch (command)
            {
                case "sign-in":
                    PrintDevices(service);
                    return 0;
                case "devices":
                    PrintDevices(service);
                    return 0;
                case "keys":
                    await Task.Delay(1500);
                    Log($"key {Describe(service.KeyStatus)}; holders: {string.Join(", ", service.KeyHolders.Select(h => h.Name))}");
                    foreach (var r in service.KeyRequests) Log($"REQUEST {r.Device.Name} ({r.Device.Id}) code {r.Code}");
                    return 0;
                case "sign-out":
                    sw.Restart();
                    await service.SignOutAsync();
                    Log($"sync: signed out (device removed, token and keys forgotten) in {sw.ElapsedMilliseconds} ms");
                    if (options.Flag("--clerk")) { await clerk.SignOutAsync(); Log("clerk: signed out"); }
                    return 0;
                case "run":
                    return await RunDevice(service, options);
                default:
                    return Usage();
            }
        }
        finally
        {
            await service.StopAsync();
        }
    }

    private static async Task<int> RunDevice(SyncService service, Options options)
    {
        var player = new PlayerController();
        player.Register(new MockProvider(ProviderId.YouTubeMusic));
        player.Register(new MockProvider(ProviderId.Spotify));
        var coordinator = new SyncCoordinator(service, new PlayerControllerAdapter(player), service.Actor);
        await coordinator.AttachAsync();
        var signIns = new Dictionary<ProviderId, ProbeSignIn> { [ProviderId.YouTubeMusic] = new(ProviderId.YouTubeMusic), [ProviderId.Spotify] = new(ProviderId.Spotify) };
        service.SignIns.Imported += i => Log($"SIGN-IN {i.Provider.RawValue()} {(i.SignedOut ? "signed out everywhere" : $"imported {i.Bytes} bytes")}, {i.LatencyMs:F0} ms after it was written (server clock)");
        foreach (var s in signIns.Values) await service.SignIns.RegisterAsync(s);
        service.Settings.Applied += (key, value, latency) => Log($"SETTING {key} = {value}, {latency:F0} ms after it was written");
        await service.Settings.ObserveAsync(SettingKeys.CrossfadeSeconds, () => SettingsSync.Json(player.CrossfadeDuration), _ => { });
        service.CommandReceived += (c, ms) => Log($"COMMAND {c.Command.Kind} from {DeviceName(service, c.FromDeviceId)}, delivered {ms:F0} ms after it was sent");
        var lastKey = Describe(service.KeyStatus);
        var lastRequests = "";
        var lastDevices = "";
        var lastPlayback = new Dictionary<DeviceId, string>();
        service.PropertyChanged += (_, e) =>
        {
            var key = Describe(service.KeyStatus);
            if (key != lastKey) { lastKey = key; Log($"KEY {key}"); }
            var requests = string.Join("; ", service.KeyRequests.Select(r => $"{r.Device.Name} code {r.Code}"));
            if (requests != lastRequests) { lastRequests = requests; if (requests.Length > 0) Log($"REQUEST {requests}"); }
            var devices = string.Join(", ", service.Devices.Select(d => $"{d.Name}{(d.Id == service.SelfId ? "*" : "")}[{d.KeyState?.ToString().ToLowerInvariant()}]"));
            if (devices != lastDevices) { lastDevices = devices; Log($"DEVICES {devices}"); }
            foreach (var (id, row) in service.Playback)
            {
                if (id == service.SelfId) continue;
                var text = $"{(row.Anchor.IsPlaying ? "playing" : "paused")} \"{row.Track?.Title ?? "(sealed)"}\" #{row.Index}";
                if (lastPlayback.GetValueOrDefault(id) == text) continue;
                lastPlayback[id] = text;
                Log($"PLAYBACK {DeviceName(service, id)}: {text} at {coordinator.LivePosition(id):F1} s");
            }
        };
        if (options.Flag("--play") && options.Value("--track") is { } spec)
        {
            // A real YouTube song (played by the silent mock engine here), so the other device can play it for real.
            var f = spec.Split('|');
            var track = new Track
            {
                ProviderID = f[0], Provider = ProviderId.YouTubeMusic, Title = f.ElementAtOrDefault(1) ?? f[0],
                Artists = f.Length > 2 ? [new ArtistRef(null, f[2])] : [],
                Duration = f.Length > 3 ? double.Parse(f[3], System.Globalization.CultureInfo.InvariantCulture) : null,
            };
            player.Play([track], 0);
            Log($"playing \"{track.Title}\" ({track.ProviderID})");
        }
        else if (options.Flag("--play"))
        {
            var tracks = ((MockProvider)player.Provider(ProviderId.YouTubeMusic)!).SampleTracks(12);
            player.Play(tracks, 0);
            Log($"playing {tracks.Count} mock tracks, first \"{tracks[0].Title}\"");
        }
        var seconds = double.Parse(options.Value("--seconds") ?? "120", System.Globalization.CultureInfo.InvariantCulture);
        var end = Clock.Elapsed + TimeSpan.FromSeconds(seconds);
        foreach (var step in (options.Value("--script") ?? "").Split(';', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
        {
            if (Clock.Elapsed > end) break;
            if (!await RunStep(step, service, coordinator, player, signIns, end)) return 1;
        }
        while (Clock.Elapsed < end && !options.Flag("--exit-after-script")) await Task.Delay(200);
        await coordinator.DetachAsync();
        return 0;
    }

    private static async Task<bool> RunStep(string step, SyncService service, SyncCoordinator coordinator, PlayerController player,
                                            Dictionary<ProviderId, ProbeSignIn> signIns, TimeSpan end)
    {
        var parts = step.Split(' ', 3, StringSplitOptions.RemoveEmptyEntries);
        var arg = parts.Length > 1 ? parts[1] : "";
        var rest = parts.Length > 2 ? parts[2] : "";
        var sw = Stopwatch.StartNew();
        TimeSpan Left() => end - Clock.Elapsed;
        switch (parts[0])
        {
            case "sleep": await Task.Delay(TimeSpan.FromSeconds(double.Parse(arg, System.Globalization.CultureInfo.InvariantCulture))); break;
            case "play": player.Resume(); Log("STEP play"); break;
            case "pause": player.Pause(); Log("STEP pause"); break;
            case "seek": player.Seek(double.Parse(arg, System.Globalization.CultureInfo.InvariantCulture)); Log($"STEP seek {arg}"); break;
            case "status":
                Log($"STATUS {player.State} \"{player.Current?.Title}\" at {player.CurrentTime:F1} s; key {Describe(service.KeyStatus)}; connection {service.Connection.State.Phase}; playback rows {service.Playback.Count}; publish error {coordinator.LastError?.Message ?? "-"}");
                break;
            case "wait-devices":
                await WaitFor(() => service.Devices.Count >= int.Parse(arg), Left(), $"{arg} devices");
                Log($"STEP {arg} devices seen after {sw.ElapsedMilliseconds} ms: {string.Join(", ", service.Devices.Select(d => d.Name))}");
                break;
            case "wait-online":
                await WaitFor(() => Resolve(service, arg) is { } d && service.IsOnline(d), Left(), $"{arg} online");
                Log($"STEP {arg} online after {sw.ElapsedMilliseconds} ms");
                break;
            case "wait-playing":
                await WaitFor(() => Resolve(service, arg) is { } d && service.Playback.TryGetValue(d.Id, out var row) && row.Anchor.IsPlaying, Left(), $"{arg} playing");
                Log($"STEP {arg} is playing (seen after {sw.ElapsedMilliseconds} ms)");
                break;
            case "play-here":
            {
                var device = Resolve(service, arg) ?? throw new InvalidOperationException($"no device {arg}");
                await coordinator.PlayHereAsync(device.Id);
                var h = coordinator.LastHandoff!;
                Log($"HANDOFF pull from {device.Name}: queue {h.FetchMs} ms, cued {h.ReadyMs} ms, playing {h.TotalMs} ms, position delta {h.PositionDeltaMs:F0} ms; now \"{player.Current?.Title}\"");
                await WaitFor(() => coordinator.LastHandoff?.SourcePaused is not null, TimeSpan.FromSeconds(20), "the source's pause ack");
                Log($"HANDOFF source paused: {coordinator.LastHandoff?.SourcePaused?.Ok}, {sw.ElapsedMilliseconds} ms after the tap");
                break;
            }
            case "send":
            {
                var device = Resolve(service, arg) ?? throw new InvalidOperationException($"no device {arg}");
                await coordinator.SendToAsync(device.Id);
                var h = coordinator.LastHandoff!;
                Log($"HANDOFF push to {device.Name}: command sent {h.FetchMs} ms, acked (playing there) {h.ReadyMs} ms, paused here {h.TotalMs} ms");
                break;
            }
            case "remote":
            {
                var device = Resolve(service, arg) ?? throw new InvalidOperationException($"no device {arg}");
                var words = rest.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                var remote = coordinator.Remote(device.Id);
                var id = words[0] switch
                {
                    "play" => await remote.Play(),
                    "pause" => await remote.Pause(),
                    "toggle" => await remote.Toggle(),
                    "next" => await remote.Next(),
                    "previous" => await remote.Previous(),
                    "stop" => await remote.Stop(),
                    "seek" => await remote.Seek(double.Parse(words[1], System.Globalization.CultureInfo.InvariantCulture)),
                    "volume" => await remote.SetVolume(double.Parse(words[1], System.Globalization.CultureInfo.InvariantCulture)),
                    _ => throw new InvalidOperationException($"unknown remote action {words[0]}"),
                };
                var sent = sw.ElapsedMilliseconds;
                var result = await service.WaitForAckAsync(id, TimeSpan.FromSeconds(30));
                Log($"REMOTE {words[0]} → {device.Name}: sent {sent} ms, acked {sw.ElapsedMilliseconds} ms, ok {result.Ok}{(result.Message is { } m ? $" ({m})" : "")}");
                break;
            }
            case "signin":
            {
                var provider = ProviderIdExtensions.Parse(arg) ?? throw new InvalidOperationException($"unknown provider {arg}");
                signIns[provider].Data = Encoding.UTF8.GetBytes(rest);
                signIns[provider].SignInDidChange?.Invoke();
                Log($"STEP fake {arg} sign-in set here ({rest.Length} chars)");
                break;
            }
            case "signin-ytm":
            {
                // The YouTube payload with fake cookies: a Windows or Mac build with test sign-ins on shows it signed in.
                var name = (arg + " " + rest).Trim();
                signIns[ProviderId.YouTubeMusic].Data = OpenMusic.Providers.YouTube.Sync.YouTubeMusicSignInTransfer.TestPayload(name.Length > 0 ? name : "Test");
                signIns[ProviderId.YouTubeMusic].SignInDidChange?.Invoke();
                Log($"STEP fake YouTube Music sign-in for {name} set here (payload format)");
                break;
            }
            case "signout":
            {
                var provider = ProviderIdExtensions.Parse(arg) ?? throw new InvalidOperationException($"unknown provider {arg}");
                await service.SignIns.SignOutAsync(provider, everywhere: rest == "everywhere");
                Log($"STEP signed out of {arg} {rest} in {sw.ElapsedMilliseconds} ms");
                break;
            }
            case "wait-signin":
            {
                var provider = ProviderIdExtensions.Parse(arg) ?? throw new InvalidOperationException($"unknown provider {arg}");
                await WaitFor(() => signIns[provider].Text == rest, Left(), $"the {arg} sign-in");
                Log($"STEP {arg} sign-in arrived and opened here after {sw.ElapsedMilliseconds} ms: \"{signIns[provider].Text}\"");
                break;
            }
            case "crossfade":
                await service.Settings.SetAsync(SettingKeys.CrossfadeSeconds, double.Parse(arg, System.Globalization.CultureInfo.InvariantCulture));
                Log($"STEP crossfade set to {arg} s");
                break;
            case "wait-setting":
                await WaitFor(() => service.Settings.ValueText(arg) == rest, Left(), $"setting {arg}");
                Log($"STEP setting {arg} = {rest} after {sw.ElapsedMilliseconds} ms");
                break;
            case "wait-request":
                await WaitFor(() => service.KeyRequests.Count > 0, Left(), "a key request");
                foreach (var r in service.KeyRequests) Log($"STEP key request from {r.Device.Name}, code {r.Code} (after {sw.ElapsedMilliseconds} ms)");
                break;
            case "allow":
                foreach (var r in service.KeyRequests.Where(r => arg == "all" || r.Device.Name.Equals(arg, StringComparison.OrdinalIgnoreCase)).ToList())
                {
                    await service.AllowKeyAsync(r);
                    Log($"STEP ALLOWED {r.Device.Name} code {r.Code} in {sw.ElapsedMilliseconds} ms");
                }
                break;
            case "wait-code":
                await WaitFor(() => service.KeyStatus is KeyStatus.Comparing, Left(), "a code to compare");
                Log($"STEP comparing code {((KeyStatus.Comparing)service.KeyStatus).Comparison.Code} with {((KeyStatus.Comparing)service.KeyStatus).Comparison.HolderName} after {sw.ElapsedMilliseconds} ms");
                break;
            case "confirm":
                await WaitFor(() => service.KeyStatus is KeyStatus.Comparing, Left(), "a code to compare");
                var code = ((KeyStatus.Comparing)service.KeyStatus).Comparison.Code;
                service.ConfirmKeyCode();
                Log($"STEP CONFIRMED code {code}");
                break;
            case "wait-key":
                await WaitFor(() => service.KeyStatus is KeyStatus.Available, Left(), "the vault key");
                Log($"STEP vault key available here after {sw.ElapsedMilliseconds} ms (key {service.LibraryKey?.Id[..8]}…)");
                break;
            case "sync-sign-out":
                await service.SignOutAsync();
                Log($"STEP sync signed out in {sw.ElapsedMilliseconds} ms");
                break;
            case "quit":
                return true;
            default:
                Log($"unknown step {step}");
                return false;
        }
        return true;
    }

    private static string Describe(KeyStatus status) => status switch
    {
        KeyStatus.Comparing c => $"comparing {c.Comparison.Code} with {c.Comparison.HolderName} (allowed {c.Comparison.Allowed}, confirmed {c.Comparison.Confirmed})",
        KeyStatus.Failed f => $"failed: {f.Message}",
        _ => status.GetType().Name.ToLowerInvariant(),
    };

    private static SyncDevice? Resolve(SyncService service, string reference) =>
        service.Devices.FirstOrDefault(d => d.Id.Value == reference || d.Name.Equals(reference, StringComparison.OrdinalIgnoreCase));

    private static string DeviceName(SyncService service, DeviceId id) => service.Devices.FirstOrDefault(d => d.Id == id)?.Name ?? id.Value;

    private static void PrintDevices(SyncService service)
    {
        foreach (var d in service.Devices)
        {
            var seen = (service.Clock.Now() - d.LastSeenAt) / 1000;
            Log($"device {d.Name}{(d.Id == service.SelfId ? " (this device)" : "")} id={d.Id} {d.Platform} {d.Model} {(service.IsOnline(d) ? "online" : "offline")}, seen {seen:F0} s ago, key {d.KeyState}");
        }
    }

    private static async Task WaitFor(Func<bool> condition, TimeSpan timeout, string what)
    {
        var deadline = Stopwatch.StartNew();
        while (!condition())
        {
            if (deadline.Elapsed > timeout) throw new TimeoutException($"timed out waiting for {what}");
            await Task.Delay(25);
        }
    }
}
