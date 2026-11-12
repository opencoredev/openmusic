using System.Text.Encodings.Web;
using System.Text.Json;
using OpenMusic.Core.Sync;

namespace OpenMusic.Sync;

/// <summary>
/// Account-wide settings that aren't secret (port of <c>SettingsSync.swift</c>): playback preferences
/// (<see cref="SettingKeys"/>) and recent searches. Each key syncs on its own and the last write by server time wins. On
/// first sync the account's value wins over this device's, and keys the account doesn't have yet are uploaded from here
/// (<c>ifAbsent</c>). While a local write of a key is pending, values arriving for it wait; once it settles the server's
/// committed value is adopted when it differs, so two devices writing at once converge. Values are JSON text as Swift's
/// JSONEncoder writes them (<see cref="Json{T}"/>). Every public method dispatches to the sync actor first. Each upload
/// belongs to the session it was made in (captured when it is made): one whose session ended before it went out is
/// never sent, and its answer is never applied to the next session.
/// </summary>
public sealed class SettingsSync
{
    public static readonly TimeSpan Debounce = TimeSpan.FromMilliseconds(400);

    /// <summary>Raised for each value applied from another device: key, JSON text, latency in ms (server clock).</summary>
    public event Action<string, string, double?>? Applied;
    public int AppliedCount { get; private set; }

    private readonly ISettingsEndpoint _endpoint;
    private readonly Func<double>? _clock;
    private readonly SyncActor _actor;
    private readonly Dictionary<string, string> _local = new();
    private readonly Dictionary<string, (string Value, double UpdatedAt)> _committed = new();
    private readonly Dictionary<string, List<Action<string>>> _observers = new();
    private readonly Dictionary<string, Func<string?>> _localValues = new();
    private readonly Dictionary<string, (string Id, Task Task, CancellationTokenSource Cancel)> _writes = new();
    private bool _initialDone;
    private int _session;

    internal SettingsSync(SyncService service, Func<double> clock)
    {
        _endpoint = service;
        _clock = clock;
        _actor = service.Actor;
    }

    internal SettingsSync(ISettingsEndpoint endpoint, Func<double>? clock, SyncActor actor)
    {
        _endpoint = endpoint;
        _clock = clock;
        _actor = actor;
    }


    /// <summary>This device's value for <paramref name="key"/> (the account's once synced), as JSON text.</summary>
    public string? ValueText(string key) => _actor.Read(() => ValueTextNow(key));

    public T? Value<T>(string key) => ValueText(key) is { } text ? JsonSerializer.Deserialize<T>(text) : default;

    private string? ValueTextNow(string key)
    {
        _actor.AssertCurrent();
        return _local.TryGetValue(key, out var v) ? v : _committed.TryGetValue(key, out var c) ? c.Value : null;
    }

    /// <summary>Sets <paramref name="key"/> for the whole account (debounced 400 ms per key). Equal to what is synced: nothing is sent.</summary>
    public async Task SetAsync<T>(string key, T value)
    {
        await _actor.Switch();
        Upload(key, Json(value));
    }

    /// <summary>Sets a raw JSON text value.</summary>
    public async Task SetTextAsync(string key, string json)
    {
        await _actor.Switch();
        Upload(key, json);
    }

    /// <summary>
    /// Calls <paramref name="handler"/> with each value of <paramref name="key"/> that arrives from another device (JSON
    /// text). <paramref name="current"/> supplies this device's value for the first sync when the account has none.
    /// </summary>
    public async Task ObserveAsync(string key, Func<string?>? current, Action<string> handler)
    {
        await _actor.Switch();
        Observe(key, current, handler);
    }

    internal void Observe(string key, Func<string?>? current, Action<string> handler)
    {
        _actor.AssertCurrent();
        if (!_observers.TryGetValue(key, out var list)) _observers[key] = list = new();
        list.Add(handler);
        if (current is not null) _localValues[key] = current;
        if (!_initialDone) return;
        if (ValueTextNow(key) is { } text)
        {
            _local[key] = text;
            handler(text);
        }
        else if (current?.Invoke() is { } mine) Upload(key, mine, debounce: false, ifAbsent: true);
    }

    /// <summary>Starts over for another account (or none). The next Apply is a first sync again.</summary>
    internal void BeginSession()
    {
        _actor.AssertCurrent();
        _session++;
        foreach (var w in _writes.Values) w.Cancel.Cancel();
        _writes.Clear();
        _local.Clear();
        _committed.Clear();
        _initialDone = false;
    }

    /// <summary>Applies the account's settings (the service calls it on every settings:list result it could open).
    /// <paramref name="present"/> is every key the account has, opened or not (null: those of <paramref name="entries"/>): a
    /// key whose value didn't open here is never filled in from this device as if the account lacked it.</summary>
    internal void Apply(IReadOnlyList<SettingEntry> entries, IReadOnlySet<string>? present = null)
    {
        _actor.AssertCurrent();
        foreach (var entry in entries)
        {
            if (_committed.TryGetValue(entry.Key, out var known) && entry.UpdatedAt <= known.UpdatedAt) continue;
            _committed[entry.Key] = (entry.Value, entry.UpdatedAt);
            Reconcile(entry.Key);
        }
        if (_initialDone || _endpoint.SettingEntries is null) return;
        _initialDone = true;
        present ??= entries.Select(e => e.Key).ToHashSet();
        foreach (var (key, current) in _localValues.ToList())
            if (!present.Contains(key) && current() is { } text) Upload(key, text, debounce: false, ifAbsent: true);
    }

    private void Reconcile(string key)
    {
        _actor.AssertCurrent();
        if (_writes.ContainsKey(key) || !_committed.TryGetValue(key, out var committed) || (_local.TryGetValue(key, out var mine) && mine == committed.Value)) return;
        _local[key] = committed.Value;
        foreach (var handler in _observers.GetValueOrDefault(key) ?? []) handler(committed.Value);
        AppliedCount++;
        Applied?.Invoke(key, committed.Value, _clock is null ? null : _clock() - committed.UpdatedAt);
    }

    private void Upload(string key, string text, bool debounce = true, bool ifAbsent = false)
    {
        _actor.AssertCurrent();
        // Before the first sync the account's values haven't arrived; they win, so hold local changes.
        if (!_initialDone && debounce) return;
        if (_local.TryGetValue(key, out var mine) && mine == text) return;
        _local[key] = text;
        if (_writes.TryGetValue(key, out var old)) old.Cancel.Cancel();
        var id = Guid.NewGuid().ToString().ToUpperInvariant();
        var session = _session;
        var cts = new CancellationTokenSource();
        _writes[key] = (id, Run(), cts);

        async Task Run()
        {
            AccountOperations.Current.Value = null;
            await Task.Yield();
            try { if (debounce) await Task.Delay(Debounce, cts.Token); } catch (OperationCanceledException) { return; }
            // Checked right before the call, which takes the service's identity with nothing awaited in between.
            if (cts.IsCancellationRequested || session != _session) return;
            if (_local.TryGetValue(key, out var value))
            {
                try
                {
                    var at = await _endpoint.PutSettingAsync(key, value, id, ifAbsent);
                    if (!ifAbsent && session == _session && at > (_committed.TryGetValue(key, out var c) ? c.UpdatedAt : 0))
                        _committed[key] = (value, at);
                }
                catch (Exception) { }   // a fill-in may not have been stored; the live query brings whatever was
            }
            if (session != _session || !_writes.TryGetValue(key, out var current) || current.Id != id) return;
            _writes.Remove(key);
            Reconcile(key);
        }
    }

    private static readonly JsonSerializerOptions SwiftOptions = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    /// <summary>JSON text as Swift's JSONEncoder writes a setting value: <c>true</c>, <c>2.5</c>, <c>["a\/b"]</c> ("/" escaped).</summary>
    public static string Json<T>(T value) => JsonSerializer.Serialize(value, SwiftOptions).Replace("/", "\\/");

    /// <summary>Waits for debounced uploads (tests).</summary>
    internal async Task Settle()
    {
        var waited = new HashSet<string>();
        while (_writes.Values.FirstOrDefault(w => !waited.Contains(w.Id)) is { Id: not null } write)
        {
            waited.Add(write.Id);
            try { await write.Task; } catch (Exception) { }
        }
    }
}
