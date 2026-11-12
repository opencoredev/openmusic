using System.Text;
using Medley.Core;
using Medley.Core.Sync;
using Medley.Sync.Convex;
using Medley.Sync.Keys;
using static Medley.Sync.Tests.TestUtil;

namespace Medley.Sync.Tests;

/// <summary>A fake provider sign-in (port of FakeSignIn in SignInAndSettingsSyncTests.swift). Used on the service's actor.</summary>
public sealed class FakeSignIn(ProviderId provider, string? text = null) : ISignInTransfer
{
    private readonly object _lock = new();
    private byte[]? _data = text is null ? null : Encoding.UTF8.GetBytes(text);
    public ProviderId Provider { get; } = provider;
    public Action? SignInDidChange { get; set; }
    public List<string> Imports { get; } = new();
    public int SignOuts;
    public bool FailImports { get; set; }
    public bool RefuseSignOuts { get; set; }

    public string? Text { get { lock (_lock) return _data is null ? null : Encoding.UTF8.GetString(_data); } }

    public Task<byte[]?> ExportSignInAsync() { lock (_lock) return Task.FromResult(_data?.ToArray()); }

    public Task ImportSignInAsync(byte[] data)
    {
        if (FailImports) throw SyncException.SignInTransferFailed("the provider rejected it");
        lock (_lock)
        {
            _data = data.ToArray();
            Imports.Add(Encoding.UTF8.GetString(data));
        }
        return Task.CompletedTask;
    }

    public Task SignOutAsync()
    {
        if (RefuseSignOuts) throw new IOException("the keychain refused");
        lock (_lock) { _data = null; SignOuts++; }
        return Task.CompletedTask;
    }

    /// <summary>A sign-in that changed here (the app calls SignInDidChange).</summary>
    public void LocalChange(string? value)
    {
        lock (_lock) _data = value is null ? null : Encoding.UTF8.GetBytes(value);
        SignInDidChange?.Invoke();
    }
}

public sealed class ClockBox(DateTimeOffset start)
{
    private DateTimeOffset _value = start;
    private readonly object _lock = new();
    public DateTimeOffset Value { get { lock (_lock) return _value; } set { lock (_lock) _value = value; } }
}

/// <summary>Wraps an HTTP poster; once blocked, requests to <paramref name="path"/> get no answer.</summary>
public sealed class PathBlocker(IHttpPoster inner, string path) : IHttpPoster
{
    private volatile bool _blocked;
    public void Block() => _blocked = true;

    public async Task<(byte[] Body, int Status)> PostAsync(Uri url, byte[] body, IReadOnlyDictionary<string, string> headers, CancellationToken cancellationToken = default)
    {
        var matches = ConvexValue.Parse(body)["path"]?.StringValue == path;
        if (matches && _blocked) throw new HttpRequestException("timed out");
        var response = await inner.PostAsync(url, body, headers, cancellationToken);
        if (matches && _blocked) throw new HttpRequestException("timed out");
        return response;
    }
}

public abstract class ServiceTests : IAsyncLifetime
{
    private readonly List<SyncService> _services = new();

    protected SyncService Device(FakeKeyServer server, string name, MemorySecretStore? store = null, IHttpPoster? http = null)
    {
        var transport = new FakeTransport { AutoFail = true };
        var service = new SyncService(Deployment, new DeviceInfo(name, DevicePlatform.Ios, "t", "1"), new SyncCredentialStore(store ?? new MemorySecretStore()),
                                      SyncActor.CreateDedicated(name), transport, http ?? server, FastOptions(fallbackAfter: 1));
        _services.Add(service);
        return service;
    }

    protected static Task SignIn(SyncService service, string user = "u") => service.SignInAsync(new FakeTokens(Jwt(user)), user);

    protected static Task<bool> WaitUntil(SyncService service, Func<bool> condition, int timeoutMs = 8000) => Eventually(service.Actor, condition, timeoutMs);

    protected static Task<T> On<T>(SyncService service, Func<T> read) => service.Actor.Run(read);

    protected static KeyComparison? Comparison(SyncService service) => service.KeyStatus is KeyStatus.Comparing c ? c.Comparison : null;

    protected static Task Register(SyncService service, ISignInTransfer transfer) => service.SignIns.RegisterAsync(transfer);

    /// <summary>The Mac holds the key; the phone asks for it. Returns both once both show a code.</summary>
    protected async Task<(SyncService Mac, SyncService Phone)> MacAndAskingPhone(FakeKeyServer server, FakeSignIn? phoneSignIn = null)
    {
        var mac = Device(server, "Leo's Mac");
        await SignIn(mac);
        Assert.True(await WaitUntil(mac, () => mac.KeyStatus is KeyStatus.Available));
        var phone = Device(server, "Leo's iPhone");
        if (phoneSignIn is not null) await Register(phone, phoneSignIn);
        await SignIn(phone);
        Assert.True(await WaitUntil(phone, () => Comparison(phone) is not null));
        return (mac, phone);
    }

    /// <summary>The Mac holds the key and the phone took it through the codes: two holders.</summary>
    protected async Task<(SyncService Mac, SyncService Phone)> TwoHolders(FakeKeyServer server)
    {
        var (mac, phone) = await MacAndAskingPhone(server);
        Assert.True(await WaitUntil(mac, () => mac.KeyRequests.Count == 1));
        await mac.AllowKeyAsync(await On(mac, () => mac.KeyRequests[0]));
        phone.ConfirmKeyCode();
        Assert.True(await WaitUntil(phone, () => phone.KeyStatus is KeyStatus.Available));
        Assert.True(await Eventually(() => server.StateOf("Leo's iPhone") is FakeKeyServer.State.Holder { Rekey: null }));
        return (mac, phone);
    }

    public Task InitializeAsync() => Task.CompletedTask;

    public async Task DisposeAsync()
    {
        foreach (var s in _services) await s.StopAsync();
    }
}
