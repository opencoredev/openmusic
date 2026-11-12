using Medley.Sync.Convex;
using Medley.Sync.Keys;

namespace Medley.Sync.Tests;

/// <summary>
/// Port of FakeKeyServer.swift: the account and key functions of the backend in memory, for several real SyncServices
/// talking to it over the HTTP fallback. Every call names its user by the <c>sub</c> of its Bearer JWT; each user has a
/// library of their own; a device token works only for its own user. <see cref="Delay"/> parks requests (sent, no answer)
/// until <see cref="CommitDelayed"/>. Key revisions move as the backend's do. Tests can make it misbehave as a malicious
/// server could.
/// </summary>
public sealed class FakeKeyServer : IHttpPoster
{
    public sealed record Exchange(string Commitment, string? Holder = null, string? HolderKey = null, string? HolderNonce = null, string? Nonce = null);
    public sealed record Rekey(string KeyId, string FromKeyId, string Wrapped, string By);

    public abstract record State
    {
        public sealed record Holder(Rekey? Rekey = null) : State;
        public sealed record Requested(Exchange? Exchange = null) : State;
        public sealed record Denied : State;
        public sealed record Granted(string KeyId, string Wrapped, string By, string Commitment) : State;
        public string Kind => this switch { Holder => "holder", Requested => "requested", Denied => "denied", _ => "granted" };
        public bool CanOpenVault => this is Holder or Granted;
    }

    public sealed class Device
    {
        public required string Id;
        public required string Name;
        public required string Token;
        public required string PublicKey;
        public required State State;
        public string? ExposedKeyId;
        public string Owner = "";
        public double LastSeen;
    }

    public enum Refusal { Retired, Withdrawn }
    public enum AnswerMischief { ConflictAndShowAgain, ConflictAndNewCommitment }

    public sealed record Row(string Provider, string? Sealed, bool Cleared, string KeyId, int Revision, double UpdatedAt, string UpdatedBy);
    public sealed record Call(string Device, string Path, ConvexValue Args, string? User);

    private sealed class Library
    {
        public string Id = "lib";
        public string? KeyId;
        public bool RotationNeeded;
        public List<Row> Vault = new();
        public int KeyRevision;
        public HashSet<string> Retired = new();
        /// <summary>Sealed content as the backend keeps it: raw values by device id or setting key, commands in order.</summary>
        public Dictionary<string, ConvexValue> Playback = new();
        public Dictionary<string, ConvexValue> Queues = new();
        public SortedDictionary<string, ConvexValue> Settings = new(StringComparer.Ordinal);
        public List<FakeCommand> Commands = new();
        /// <summary>The key the last rotation replaced: what a device publishes about itself is still taken under it.</summary>
        public string? PreviousKey;
    }

    private sealed class FakeCommand
    {
        public required string Id, From, To;
        public required ConvexValue Command;
        public double CreatedAt;
        public ConvexValue? Result;
    }

    private readonly object _lock = new();
    private readonly List<Device> _devices = new();
    private readonly Dictionary<string, Library> _libraries = new();
    private string _current = "";
    private string? _focus;
    private readonly List<Call> _calls = new();
    private double _time = 1_000_000;
    private Func<string, string, Exchange, Exchange>? _rewrite;
    private AnswerMischief? _answerMischief;
    private bool _loseClaimAnswer, _refuseClaims, _loseRegisterAnswer, _refuseRegistrations, _loseRotateAnswer, _unreachable, _legacyUnregister;
    private Action<string>? _onClaim, _onRegister;
    private readonly HashSet<string> _away = new();
    private readonly Dictionary<string, (Refusal Reason, double ExpiresAt)> _refused = new();
    private readonly Dictionary<string, (double Start, int Count)> _withdrawalWindow = new();
    private int _maxDevices = 32;
    private readonly Dictionary<string, int> _delays = new();
    private readonly List<(string Path, ConvexValue Args, string? User)> _parked = new();
    private readonly Dictionary<string, HashSet<string>> _knows = new();
    private readonly List<string> _violations = new();
    private int _librariesMade;

    public const double RefusalTtl = 30.0 * 24 * 3600_000;
    public const int WithdrawalsPerHour = 10;
    public const int MaxWithdrawals = 50;

    // MARK: The current library

    private Library Lib
    {
        get
        {
            if (_libraries.TryGetValue(_current, out var lib)) return lib;
            _librariesMade++;
            lib = new Library { Id = _librariesMade == 1 ? "lib" : $"lib-{_librariesMade}" };
            _libraries[_current] = lib;
            return lib;
        }
    }
    private void Bump() => Lib.KeyRevision++;
    private List<int> Mine => Enumerable.Range(0, _devices.Count).Where(i => _devices[i].Owner == _current).ToList();

    private T Focusing<T>(string? user, Func<T> body)
    {
        var saved = _current;
        _current = user ?? _focus ?? "";
        try { return body(); } finally { _current = saved; }
    }

    // MARK: Observing

    public IReadOnlyList<string> Violations { get { lock (_lock) return _violations.ToList(); } }
    public IReadOnlyList<Device> Devices { get { lock (_lock) return _devices.ToList(); } }
    public string? KeyId { get { lock (_lock) return Focusing(null, () => _libraries.GetValueOrDefault(_current)?.KeyId); } }
    public int KeyRevision { get { lock (_lock) return Focusing(null, () => _libraries.GetValueOrDefault(_current)?.KeyRevision ?? 0); } }
    public IReadOnlyList<Row> Vault { get { lock (_lock) return Focusing(null, () => _libraries.GetValueOrDefault(_current)?.Vault.ToList() ?? []); } }
    public IReadOnlyList<Call> Calls { get { lock (_lock) return _calls.ToList(); } }
    public IReadOnlyList<Call> CallsTo(string path, string? device = null) => Calls.Where(c => c.Path == path && (device is null || c.Device == device)).ToList();
    public Device? DeviceNamed(string name) => Devices.FirstOrDefault(d => d.Name == name);
    public State? StateOf(string name) { lock (_lock) return _devices.FirstOrDefault(d => d.Name == name)?.State; }
    public int Parked { get { lock (_lock) return _parked.Count; } }
    public Refusal? RefusalOf(string token, string user) { lock (_lock) return Refused($"{user}|{token}"); }

    public void AdvanceTime(double ms) { lock (_lock) _time += ms; }
    public void SetMaxDevices(int count) { lock (_lock) _maxDevices = count; }
    public void Rewrite(Func<string, string, Exchange, Exchange>? change) { lock (_lock) _rewrite = change; }
    public void SetAnswerMischief(AnswerMischief? mischief) { lock (_lock) _answerMischief = mischief; }
    public void LoseClaimAnswer(bool lose, Action<string>? onClaim = null) { lock (_lock) { _loseClaimAnswer = lose; _onClaim = onClaim; } }
    public void LoseRegisterAnswer(bool lose, Action<string>? onRegister = null) { lock (_lock) { _loseRegisterAnswer = lose; _onRegister = onRegister; } }
    public void LoseRotateAnswer(bool lose) { lock (_lock) _loseRotateAnswer = lose; }
    public void RefuseRegistrations(bool refuse) { lock (_lock) _refuseRegistrations = refuse; }
    public void SetUnreachable(bool unreachable) { lock (_lock) _unreachable = unreachable; }
    public void SetAway(string name, bool away) { lock (_lock) { if (away) _away.Add(name); else _away.Remove(name); } }
    public void RefuseClaims(bool refuse) { lock (_lock) _refuseClaims = refuse; }
    public void LegacyUnregister(bool legacy) { lock (_lock) _legacyUnregister = legacy; }
    /// <summary>Parks the next <paramref name="count"/> requests to <paramref name="path"/> (sent, no answer) until CommitDelayed.</summary>
    public void Delay(string path, int count = 1) { lock (_lock) _delays[path] = _delays.GetValueOrDefault(path) + count; }

    public void CommitDelayed()
    {
        lock (_lock)
        {
            var parked = _parked.ToList();
            _parked.Clear();
            _delays.Clear();
            foreach (var r in parked) Process(r.Path, r.Args, r.User, sent: true);
        }
    }

    public void AddAskingDevice(string name, string commitment, string? publicKey = null)
    {
        lock (_lock)
        {
            Focusing<bool>(null, () =>
            {
                _devices.Add(new Device
                {
                    Id = $"made-up-{_devices.Count + 1}-{Guid.NewGuid().ToString()[..4]}", Name = name, Token = Guid.NewGuid().ToString(),
                    PublicKey = publicKey ?? DeviceKeyPair.Generate().PublicKey, State = new State.Requested(new Exchange(commitment)), Owner = _current,
                });
                Bump();
                return true;
            });
        }
    }

    public void SetState(string name, State state)
    {
        lock (_lock)
        {
            var i = _devices.FindIndex(d => d.Name == name);
            if (i < 0) return;
            Focusing<bool>(_devices[i].Owner, () => { _devices[i].State = state; Bump(); return true; });
        }
    }

    public void SetLibrary(string? keyId, bool rotationNeeded)
    {
        lock (_lock) Focusing<bool>(null, () => { Lib.KeyId = keyId; Lib.RotationNeeded = rotationNeeded; Bump(); return true; });
    }

    /// <summary>
    /// A device that could open <paramref name="user"/>'s vault left: that library needs a new key. One step under the lock
    /// (reading KeyId and then calling SetLibrary would act on whichever library the last call focused on).
    /// </summary>
    public void RequireRotation(string user)
    {
        lock (_lock) Focusing<bool>(user, () =>
        {
            if (!_libraries.ContainsKey(_current) || Lib.KeyId is null) return false;
            Lib.RotationNeeded = true;
            Bump();
            return true;
        });
    }

    public void PutRow(Row row) { lock (_lock) Focusing<bool>(null, () => { StoreRow(row); return true; }); }

    private void StoreRow(Row row)
    {
        Lib.Vault.RemoveAll(r => r.Provider == row.Provider);
        Lib.Vault.Add(row);
    }

    public void Remove(string name)
    {
        lock (_lock)
        {
            var i = _devices.FindIndex(d => d.Name == name);
            if (i < 0) return;
            Focusing<bool>(_devices[i].Owner, () => { RemoveDevice(i); return true; });
        }
    }

    private void RemoveDevice(int i)
    {
        var gone = _devices[i];
        _devices.RemoveAt(i);
        Lib.Playback.Remove(gone.Id);
        Lib.Queues.Remove(gone.Id);
        Lib.Commands.RemoveAll(c => c.From == gone.Id || c.To == gone.Id);
        if (!_legacyUnregister) Refuse(gone.Token, gone.Owner, Refusal.Retired);
        if (Mine.Count == 0)
        {
            _libraries.Remove(_current);
            return;
        }
        if (Lib.KeyId is not null && !ResetIfStranded() && (gone.State.CanOpenVault || gone.ExposedKeyId == Lib.KeyId)) Lib.RotationNeeded = true;
        Bump();
    }

    private bool ResetIfStranded()
    {
        if (Lib.KeyId is not { } current || Mine.Any(i => _devices[i].State.CanOpenVault)) return false;
        foreach (var i in Mine)
        {
            var d = _devices[i];
            var known = _knows.GetValueOrDefault(d.Token) ?? [];
            var reachable = known.Contains(current) || (d.State is State.Holder { Rekey: { } r } && r.KeyId == current && known.Contains(r.FromKeyId));
            if (reachable) _violations.Add($"reset of {current} while {d.Name} ({d.State.Kind}) could still reach it");
        }
        Lib.Retired.Add(current);
        Lib.KeyId = null;
        Lib.RotationNeeded = false;
        // Settings were sealed under the lost key: deleted, as resetVaultKey does.
        Lib.Settings.Clear();
        Lib.PreviousKey = null;
        for (var j = 0; j < Lib.Vault.Count; j++)
        {
            var row = Lib.Vault[j];
            if (row.Sealed is not null) Lib.Vault[j] = row with { Sealed = null, Cleared = true, KeyId = new string('0', 32), Revision = row.Revision + 1, UpdatedAt = Tick() };
        }
        foreach (var j in Mine) _devices[j].State = new State.Requested();
        Bump();
        return true;
    }

    private double Tick() => ++_time;

    private Refusal? Refused(string key) => _refused.TryGetValue(key, out var r) && r.ExpiresAt > _time ? r.Reason : null;

    private void Refuse(string token, string user, Refusal reason)
    {
        var key = $"{user}|{token}";
        var kept = Refused(key) == Refusal.Retired ? Refusal.Retired : reason;
        _refused[key] = (kept, Math.Max(_time + RefusalTtl, _refused.GetValueOrDefault(key).ExpiresAt));
    }

    private void Learn(string token, params string?[] keys)
    {
        if (!_knows.TryGetValue(token, out var set)) _knows[token] = set = new();
        foreach (var k in keys) if (k is not null) set.Add(k);
    }

    // MARK: HTTP

    public Task<(byte[] Body, int Status)> PostAsync(Uri url, byte[] body, IReadOnlyDictionary<string, string> headers, CancellationToken cancellationToken = default)
    {
        var parsed = ConvexValue.Parse(body);
        lock (_lock)
        {
            var path = parsed["path"]?.StringValue;
            var args = parsed["args"]?.ArrayValue?.FirstOrDefault();
            if (path is null || args is null) return Task.FromResult((Fail("invalidArgument", "no args").JsonBytes(), 200));
            var user = headers.TryGetValue("Authorization", out var auth) && auth.StartsWith("Bearer ", StringComparison.Ordinal)
                ? JwtClaims.Decode(auth[7..])?.Sub : null;
            if (!Queries.Contains(path) && _delays.TryGetValue(path, out var left) && left > 0)
            {
                _delays[path] = left - 1;
                var token = args["token"]?.StringValue ?? "";
                _calls.Add(new Call(_devices.FirstOrDefault(d => d.Token == token)?.Name ?? "?", path, args, user));
                _parked.Add((path, args, user));
                throw new HttpRequestException("The request timed out.");
            }
            return Task.FromResult((Process(path, args, user).JsonBytes(), 200));
        }
    }

    private static readonly HashSet<string> Queries = ["devices:list", "vault:list", "settings:list", "playback:list", "commands:incoming", "commands:outgoing", "playback:queue"];

    private static ConvexValue Ok(ConvexValue value) => ConvexValue.Object(("status", ConvexValue.String("success")), ("value", value));
    private ConvexValue Now() => Ok(ConvexValue.Object(("serverNow", ConvexValue.Float64(Tick()))));
    private static ConvexValue Fail(string code, string message, int? revision = null)
    {
        var data = new List<(string, ConvexValue)> { ("code", ConvexValue.String(code)), ("message", ConvexValue.String(message)) };
        if (revision is { } r) data.Add(("revision", ConvexValue.Float64(r)));
        return ConvexValue.Object(("status", ConvexValue.String("error")), ("errorMessage", ConvexValue.String(message)), ("errorData", ConvexValue.Object(data.ToArray())));
    }

    private static string? Str(ConvexValue a, string key) => a[key]?.StringValue;
    private static int? Int(ConvexValue a, string key) => a[key]?.DoubleValue is { } d ? (int)d : null;

    private ConvexValue Process(string path, ConvexValue args, string? user, bool sent = false)
    {
        var token = Str(args, "token") ?? "";
        var named = _devices.FindIndex(d => d.Token == token);
        _calls.Add(new Call(named >= 0 ? _devices[named].Name : "?", path, args, user));
        if (user is null) return Fail("unauthenticated", "Sign in first.");
        _focus = user;
        return Focusing(user, () =>
        {
            if (path == "account:register") return Register(args, token, sent);
            if (path == "account:unregister") return Unregister(token, sent);
            if (_unreachable && !sent) return Fail("unavailable", "Can't reach the server.");
            if (named < 0 || _devices[named].Owner != user) return Fail("unauthorized", "Unknown device.");
            var me = named;
            if (_away.Contains(_devices[me].Name) && !sent) return Fail("unavailable", "Can't reach the server.");
            _devices[me].LastSeen = Tick();
            switch (path)
            {
                case "devices:list": return List(me);
                case "vault:list": return Ok(ConvexValue.Array(Lib.Vault.Select(RowValue)));
                case "playback:publish": return Publish(args, me);
                case "playback:clear":
                    Lib.Playback.Remove(_devices[me].Id);
                    Lib.Queues.Remove(_devices[me].Id);
                    return Now();
                case "playback:list": return Ok(ConvexValue.Array(Lib.Playback.Values));
                case "playback:queue": return Ok(Lib.Queues.GetValueOrDefault(Str(args, "deviceId") ?? "") ?? ConvexValue.Null);
                case "settings:put": return PutSetting(args, me);
                case "settings:list": return Ok(ConvexValue.Array(Lib.Settings.Values));
                case "commands:send": return SendCommand(args, me);
                case "commands:ack": return AckCommand(args, me);
                case "commands:incoming":
                    return Ok(ConvexValue.Array(Lib.Commands.Where(c => c.To == _devices[me].Id && c.Result is null).Select(c => ConvexValue.Object(
                        ("id", ConvexValue.String(c.Id)), ("fromDeviceId", ConvexValue.String(c.From)), ("command", c.Command),
                        ("createdAt", ConvexValue.Float64(c.CreatedAt)), ("expiresAt", ConvexValue.Float64(c.CreatedAt + 120_000))))));
                case "commands:outgoing":
                    return Ok(ConvexValue.Array(Lib.Commands.Where(c => c.From == _devices[me].Id).Reverse().Select(c =>
                    {
                        var fields = new List<(string, ConvexValue)>
                        {
                            ("id", ConvexValue.String(c.Id)), ("toDeviceId", ConvexValue.String(c.To)), ("kind", c.Command["kind"] ?? ConvexValue.Null),
                            ("createdAt", ConvexValue.Float64(c.CreatedAt)), ("expiresAt", ConvexValue.Float64(c.CreatedAt + 120_000)),
                        };
                        if (c.Result is { } result) { fields.Add(("result", result)); fields.Add(("ackedAt", ConvexValue.Float64(c.CreatedAt + 1))); }
                        return ConvexValue.Object(fields.ToArray());
                    })));
                case "vault:put": return Put(args, me);
                case "keys:request": return Request(args, me);
                case "keys:answer": return Answer(args, me);
                case "keys:reveal": return Reveal(args, me);
                case "keys:grant": return Grant(args, me);
                case "keys:accept": return Accept(args, me);
                case "keys:deny": return Deny(args, me);
                case "keys:claim": return Claim(args, me);
                case "keys:rotate":
                    var answer = Rotate(args, me);
                    if (!_loseRotateAnswer) return answer;
                    _loseRotateAnswer = false;
                    _away.Add(_devices[me].Name);
                    return Fail("internal", "The answer was lost.");
                case "keys:release": return Release(args, me);
                case "devices:remove":
                    if (Target(args) is not { } target) return Fail("notFound", "No such device");
                    RemoveDevice(target);
                    return Now();
                default: return Now();
            }
        });
    }

    private ConvexValue Register(ConvexValue args, string token, bool sent)
    {
        if (_unreachable && !sent) return Fail("unavailable", "Can't reach the server.");
        _onRegister?.Invoke(token);
        if (_refuseRegistrations) return Fail("unauthorized", "Unknown device.");
        if (Refused($"{_current}|{token}") is not null) return Fail("unauthorized", "This device signed out.");
        var answer = Registered(args, token);
        return _loseRegisterAnswer ? Fail("internal", "The answer was lost.") : answer;
    }

    private ConvexValue RegisterAnswer(string id, State state) => Ok(ConvexValue.Object(
        ("deviceId", ConvexValue.String(id)), ("libraryId", ConvexValue.String(Lib.Id)), ("keyId", ConvexValue.OptionalString(Lib.KeyId)),
        ("keyState", ConvexValue.String(state.Kind)), ("keyRevision", ConvexValue.Float64(Lib.KeyRevision)), ("serverNow", ConvexValue.Float64(Tick()))));

    private ConvexValue Registered(ConvexValue args, string token)
    {
        if (_devices.FirstOrDefault(d => d.Token == token) is { } known)
            return known.Owner == _current ? RegisterAnswer(known.Id, known.State) : Fail("unauthorized", "Unknown device.");
        var id = $"d{_devices.Count + 1}-{Guid.NewGuid().ToString()[..4]}";
        if (Mine.Count >= _maxDevices) RemoveDevice(Mine.MinBy(i => _devices[i].LastSeen));
        var proposed = Str(args, "keyId");
        State state;
        if (Lib.KeyId is null && proposed is not null && !Lib.Retired.Contains(proposed))
        {
            Lib.KeyId = proposed;
            Learn(token, proposed);
            state = new State.Holder();
        }
        else state = new State.Requested();
        _devices.Add(new Device
        {
            Id = id, Name = args["device"]?["name"]?.StringValue ?? id, Token = token, PublicKey = Str(args, "publicKey") ?? "",
            State = state, ExposedKeyId = state is State.Holder ? Lib.KeyId : null, Owner = _current, LastSeen = Tick(),
        });
        Bump();
        return RegisterAnswer(id, state);
    }

    private ConvexValue Unregister(string token, bool sent)
    {
        var caller = _devices.FirstOrDefault(d => d.Token == token);
        if (!sent && (_unreachable || (caller is not null && _away.Contains(caller.Name)))) return Fail("unavailable", "Can't reach the server.");
        var answer = new List<(string, ConvexValue)> { ("removed", ConvexValue.Bool(false)), ("serverNow", ConvexValue.Float64(Tick())) };
        if (!_legacyUnregister) answer.Add(("cancelled", ConvexValue.Bool(true)));
        var i = _devices.FindIndex(d => d.Token == token && d.Owner == _current);
        if (i >= 0)
        {
            RemoveDevice(i);
            answer[0] = ("removed", ConvexValue.Bool(true));
            return Ok(ConvexValue.Object(answer.ToArray()));
        }
        if (_legacyUnregister || Refused($"{_current}|{token}") is not null) return Ok(ConvexValue.Object(answer.ToArray()));
        const double hour = 3600_000;
        var start = _time - _time % hour;
        var window = _withdrawalWindow.TryGetValue(_current, out var w) && w.Start == start ? w : (start, 0);
        var withdrawn = _refused.Count(kv => kv.Key.StartsWith($"{_current}|", StringComparison.Ordinal) && kv.Value.Reason == Refusal.Withdrawn && kv.Value.ExpiresAt > _time);
        if (window.Item2 >= WithdrawalsPerHour || withdrawn >= MaxWithdrawals) return Fail("rateLimited", "Too many sign-outs of unknown devices. Try again later.");
        _withdrawalWindow[_current] = (start, window.Item2 + 1);
        Refuse(token, _current, Refusal.Withdrawn);
        return Ok(ConvexValue.Object(answer.ToArray()));
    }

    private ConvexValue ExchangeValue(Exchange e)
    {
        var o = new List<(string, ConvexValue)> { ("commitment", ConvexValue.String(e.Commitment)), ("at", ConvexValue.Float64(_time)) };
        if (e is { Holder: { } holder, HolderKey: { } key, HolderNonce: { } nonce })
        {
            o.Add(("holder", ConvexValue.String(holder)));
            o.Add(("holderKey", ConvexValue.String(key)));
            o.Add(("holderNonce", ConvexValue.String(nonce)));
            if (e.Nonce is { } revealed) { o.Add(("phase", ConvexValue.String("revealed"))); o.Add(("nonce", ConvexValue.String(revealed))); }
            else o.Add(("phase", ConvexValue.String("answered")));
        }
        else o.Add(("phase", ConvexValue.String("committed")));
        return ConvexValue.Object(o.ToArray());
    }

    /// <summary>What devices:list answers <paramref name="name"/> now (to hand it to that device later, as a late list).</summary>
    public DeviceListResult ListResultFor(string name)
    {
        lock (_lock)
        {
            var i = _devices.FindIndex(d => d.Name == name);
            return Focusing(_devices[i].Owner, () => List(i)["value"]!).Decode<DeviceListResult>();
        }
    }

    private ConvexValue List(int viewer)
    {
        var me = _devices[viewer];
        var rows = Mine.Select(i => _devices[i]).Select(d =>
        {
            var exchange = d.State is State.Requested { Exchange: { } e } ? ExchangeValue(_rewrite?.Invoke(me.Name, d.Name, e) ?? e) : ConvexValue.Null;
            return ConvexValue.Object(("id", ConvexValue.String(d.Id)), ("name", ConvexValue.String(d.Name)), ("platform", ConvexValue.String("ios")),
                ("model", ConvexValue.String("m")), ("appVersion", ConvexValue.String("1")), ("createdAt", ConvexValue.Float64(1)),
                ("lastSeenAt", ConvexValue.Float64(_time)), ("keyState", ConvexValue.String(d.State.Kind)), ("publicKey", ConvexValue.String(d.PublicKey)),
                ("exchange", exchange));
        });
        var grant = me.State is State.Granted g
            ? ConvexValue.Object(("keyId", ConvexValue.String(g.KeyId)), ("wrapped", ConvexValue.String(g.Wrapped)), ("fromDeviceId", ConvexValue.String(g.By)), ("commitment", ConvexValue.String(g.Commitment)))
            : ConvexValue.Null;
        var rekey = me.State is State.Holder { Rekey: { } r }
            ? ConvexValue.Object(("keyId", ConvexValue.String(r.KeyId)), ("fromKeyId", ConvexValue.String(r.FromKeyId)), ("wrapped", ConvexValue.String(r.Wrapped)), ("fromDeviceId", ConvexValue.String(r.By)))
            : ConvexValue.Null;
        return Ok(ConvexValue.Object(("selfId", ConvexValue.String(me.Id)), ("libraryId", ConvexValue.String(Lib.Id)), ("keyId", ConvexValue.OptionalString(Lib.KeyId)),
            ("rotationNeeded", ConvexValue.Bool(Lib.RotationNeeded)), ("keyRevision", ConvexValue.Float64(Lib.KeyRevision)),
            ("devices", ConvexValue.Array(rows)), ("grant", grant), ("rekey", rekey)));
    }

    private static ConvexValue RowValue(Row r) => ConvexValue.Object(("provider", ConvexValue.String(r.Provider)), ("sealed", ConvexValue.OptionalString(r.Sealed)),
        ("cleared", ConvexValue.Bool(r.Cleared)), ("keyId", ConvexValue.String(r.KeyId)), ("revision", ConvexValue.Float64(r.Revision)),
        ("updatedAt", ConvexValue.Float64(r.UpdatedAt)), ("updatedBy", ConvexValue.String(r.UpdatedBy)));

    private ConvexValue Put(ConvexValue args, int me)
    {
        if (Str(args, "provider") is not { } provider || Int(args, "baseRevision") is not { } baseRevision) return Fail("invalidArgument", "args");
        if (Str(args, "keyId") != Lib.KeyId) return Fail("forbidden", "This data is sealed with a key the library doesn't use.");
        if (Lib.RotationNeeded) return Fail("forbidden", "Your account's key is being replaced.");
        var current = Lib.Vault.FirstOrDefault(r => r.Provider == provider)?.Revision ?? 0;
        if (baseRevision != current) return Fail("conflict", "Another device changed this sign-in first.", current);
        var at = Tick();
        StoreRow(new Row(provider, Str(args, "sealed"), false, Lib.KeyId ?? "", current + 1, at, _devices[me].Id));
        return Ok(ConvexValue.Object(("updatedAt", ConvexValue.Float64(at)), ("revision", ConvexValue.Float64(current + 1)), ("serverNow", ConvexValue.Float64(at))));
    }

    private int? Target(ConvexValue args)
    {
        var id = Str(args, "deviceId");
        var i = _devices.FindIndex(d => d.Id == id && d.Owner == _current);
        return i >= 0 ? i : null;
    }

    private ConvexValue Request(ConvexValue args, int me)
    {
        if (Str(args, "commitment") is not { } commitment) return Fail("invalidArgument", "commitment");
        Bump();   // before anything, as the backend does
        if (_devices[me].State is State.Holder) return Now();
        if (_devices[me].State is State.Requested { Exchange: { } e } && e.Commitment == commitment) { ResetIfStranded(); return Now(); }
        _devices[me].State = new State.Requested(new Exchange(commitment));
        ResetIfStranded();
        return Now();
    }

    private ConvexValue Answer(ConvexValue args, int me)
    {
        if (_devices[me].State is not State.Holder) return Fail("forbidden", "not a holder");
        if (Target(args) is not { } t || _devices[t].State is not State.Requested { Exchange: { } e } || e.Commitment != Str(args, "commitment") || Str(args, "nonce") is not { } nonce)
            return Fail("conflict", "That device isn't asking any more.");
        if (e.Holder is { } holder)
        {
            if (holder != _devices[me].Id || e.HolderNonce != nonce) return Fail("conflict", "Another device answered first.");
            Bump();
            return Now();
        }
        switch (_answerMischief)
        {
            case AnswerMischief.ConflictAndShowAgain:
                return Fail("conflict", "Another device answered first.");
            case AnswerMischief.ConflictAndNewCommitment:
                _devices[t].State = new State.Requested(new Exchange(Convert.ToBase64String(KeyExchange.Nonce())));
                Bump();
                return Fail("conflict", "That device isn't asking any more.");
        }
        _devices[t].State = new State.Requested(e with { Holder = _devices[me].Id, HolderKey = _devices[me].PublicKey, HolderNonce = nonce });
        Bump();
        return Now();
    }

    private ConvexValue Reveal(ConvexValue args, int me)
    {
        if (_devices[me].State is not State.Requested { Exchange: { } e } || e.Commitment != Str(args, "commitment") || e.Holder is null || Str(args, "nonce") is not { } nonce)
            return Fail("conflict", "No device has answered yet.");
        if (e.Nonce is { } revealed)
        {
            if (revealed != nonce) return Fail("conflict", "already revealed");
            Bump();
            return Now();
        }
        _devices[me].State = new State.Requested(e with { Nonce = nonce });
        Bump();
        return Now();
    }

    private ConvexValue Grant(ConvexValue args, int me)
    {
        if (_devices[me].State is not State.Holder) return Fail("forbidden", "not a holder");
        if (Str(args, "keyId") != Lib.KeyId) return Fail("forbidden", "That isn't your account's key.");
        if (Lib.RotationNeeded) return Fail("conflict", "Your account's key is being replaced.");
        if (Target(args) is { } t0 && _devices[t0].State is State.Granted g && g.By == _devices[me].Id && g.Wrapped == Str(args, "wrapped") && g.Commitment == Str(args, "commitment"))
        {
            Bump();
            return Now();
        }
        if (Target(args) is not { } t || _devices[t].State is not State.Requested { Exchange: { } e } || e.Nonce is null || e.Holder != _devices[me].Id
            || Str(args, "commitment") is not { } commitment || e.Commitment != commitment || Str(args, "wrapped") is not { } wrapped || Lib.KeyId is not { } keyId)
            return Fail("conflict", "That device's request changed.");
        _devices[t].State = new State.Granted(keyId, wrapped, _devices[me].Id, commitment);
        _devices[t].ExposedKeyId = keyId;
        Bump();
        return Now();
    }

    private ConvexValue Accept(ConvexValue args, int me)
    {
        var keyId = Str(args, "keyId");
        Learn(_devices[me].Token, keyId);
        switch (_devices[me].State)
        {
            case State.Holder { Rekey: { } rekey } when rekey.KeyId == keyId: _devices[me].State = new State.Holder(); break;
            case State.Holder: break;
            case State.Granted g when g.KeyId == keyId && keyId == Lib.KeyId: _devices[me].State = new State.Holder(); break;
            default: return Fail("forbidden", "There is no grant of that key for this device.");
        }
        Bump();
        return Now();
    }

    private ConvexValue Deny(ConvexValue args, int me)
    {
        if (_devices[me].State is not State.Holder) return Fail("forbidden", "not a holder");
        if (Target(args) is { } t && _devices[t].State is State.Requested) _devices[t].State = new State.Denied();
        Bump();
        return Now();
    }

    private ConvexValue Release(ConvexValue args, int me)
    {
        if (_devices[me].State is not State.Holder holder) return Now();
        if (Str(args, "keyId") is not { } held) return Fail("invalidArgument", "keyId");
        if (held == Lib.KeyId) return Fail("conflict", "This device has your account's key.");
        if (Str(args, "accountKeyId") != Lib.KeyId) return Fail("conflict", "Your account's key changed.");
        if (Str(args, "rekeyKeyId") != holder.Rekey?.KeyId) return Fail("conflict", "A new key is waiting for this device.");
        if (Int(args, "keyRevision") is not { } seen) return Fail("invalidArgument", "keyRevision");
        if (seen != Lib.KeyRevision) return Fail("conflict", "Your account's keys changed since this device looked.");
        _devices[me].State = new State.Requested();
        Bump();
        ResetIfStranded();
        return Now();
    }

    private ConvexValue Claim(ConvexValue args, int me)
    {
        if (Str(args, "keyId") is not { } keyId) return Fail("invalidArgument", "keyId");
        if (Int(args, "keyRevision") is not { } seen) return Fail("invalidArgument", "keyRevision");
        Learn(_devices[me].Token, keyId);
        _onClaim?.Invoke(keyId);
        if (_refuseClaims) return Fail("forbidden", "That key was used before. Make a new one.");
        ConvexValue Answer() => Ok(ConvexValue.Object(("keyId", ConvexValue.String(keyId)), ("keyRevision", ConvexValue.Float64(Lib.KeyRevision)), ("serverNow", ConvexValue.Float64(Tick()))));
        if (Lib.KeyId is { } current)
            return current == keyId && _devices[me].State is State.Holder ? Answer() : Fail("forbidden", "Your account already has a key.");
        if (Lib.Retired.Contains(keyId)) return Fail("forbidden", "That key was used before. Make a new one.");
        if (seen != Lib.KeyRevision) return Fail("conflict", "Your account's keys changed since this device looked.");
        Lib.KeyId = keyId;
        Lib.RotationNeeded = false;
        _devices[me].State = new State.Holder();
        _devices[me].ExposedKeyId = keyId;
        Bump();
        return _loseClaimAnswer ? Fail("internal", "The answer was lost.") : Answer();
    }

    // MARK: Sealed content (playback, queues, settings, commands)

    /// <summary>Content is taken only sealed (<c>{ v: 1, keyId, sealed }</c>) under the account's key, or for what a device
    /// publishes about itself the key the last rotation replaced, as on the backend.</summary>
    private bool Accepts(ConvexValue? sealedValue, bool previous)
    {
        if (sealedValue is null || sealedValue["v"]?.DoubleValue != 1 || Str(sealedValue, "keyId") is not { } keyId || Str(sealedValue, "sealed") is not { } text
            || Lib.KeyId is not { } current) return false;
        try { Convert.FromBase64String(text); } catch (FormatException) { return false; }
        return keyId == current || (previous && keyId == Lib.PreviousKey);
    }

    private ConvexValue Publish(ConvexValue args, int me)
    {
        var id = _devices[me].Id;
        var row = Lib.Playback.TryGetValue(id, out var old) ? new Dictionary<string, ConvexValue>(old.ObjectValue!) : new() { ["deviceId"] = ConvexValue.String(id), ["content"] = ConvexValue.Null };
        var version = row.TryGetValue("queueVersion", out var v) ? v.DoubleValue ?? 0 : 0;
        switch (args["content"])
        {
            case null: break;
            case { IsNull: true }:
                if (!row["content"].IsNull || Lib.Queues.ContainsKey(id)) version += 1;
                row["content"] = ConvexValue.Null;
                Lib.Queues.Remove(id);
                break;
            case var content:
                if (!Accepts(content["playback"], true) || !Accepts(content["queue"], true)) return Fail("forbidden", "This data is sealed with a key your account doesn't use.");
                version += 1;
                row["content"] = content["playback"]!;
                Lib.Queues[id] = ConvexValue.Object(("content", content["queue"]!), ("version", ConvexValue.Float64(version)));
                break;
        }
        var at = Tick();
        row["queueVersion"] = ConvexValue.Float64(version);
        row["anchor"] = args["anchor"] ?? ConvexValue.Null;
        row["updatedAt"] = ConvexValue.Float64(at);
        Lib.Playback[id] = ConvexValue.Object(row);
        var positionAt = args["anchor"]?["positionAt"]?.DoubleValue ?? at;
        return Ok(ConvexValue.Object(("serverNow", ConvexValue.Float64(at)), ("positionAt", ConvexValue.Float64(Math.Min(at, positionAt))), ("queueVersion", ConvexValue.Float64(version))));
    }

    private ConvexValue PutSetting(ConvexValue args, int me)
    {
        if (Str(args, "key") is not { } key) return Fail("invalidArgument", "key");
        if (!Accepts(args["value"], false)) return Fail("forbidden", "This data is sealed with a key your account doesn't use.");
        if (args["ifAbsent"] is { } ifAbsent && ifAbsent == ConvexValue.Bool(true) && Lib.Settings.TryGetValue(key, out var existing))
            return Ok(ConvexValue.Object(("updatedAt", existing["updatedAt"]!), ("serverNow", ConvexValue.Float64(Tick()))));
        var at = Tick();
        var fields = new List<(string, ConvexValue)> { ("key", ConvexValue.String(key)), ("value", args["value"]!), ("updatedAt", ConvexValue.Float64(at)), ("updatedBy", ConvexValue.String(_devices[me].Id)) };
        if (args["writeId"] is { IsNull: false } writeId) fields.Add(("writeId", writeId));
        Lib.Settings[key] = ConvexValue.Object(fields.ToArray());
        return Ok(ConvexValue.Object(("updatedAt", ConvexValue.Float64(at)), ("serverNow", ConvexValue.Float64(at))));
    }

    private ConvexValue SendCommand(ConvexValue args, int me)
    {
        if (args["command"] is not { } command || Str(args, "toDeviceId") is not { } to) return Fail("invalidArgument", "command");
        if (Str(command, "kind") == "takeOver" && !Accepts(command["content"], true)) return Fail("forbidden", "This data is sealed with a key your account doesn't use.");
        var at = Tick();
        var id = $"c{Lib.Commands.Count + 1}";
        Lib.Commands.Add(new FakeCommand { Id = id, From = _devices[me].Id, To = to, Command = command, CreatedAt = at });
        return Ok(ConvexValue.Object(("commandId", ConvexValue.String(id)), ("expiresAt", ConvexValue.Float64(at + 120_000)), ("serverNow", ConvexValue.Float64(at))));
    }

    private ConvexValue AckCommand(ConvexValue args, int me)
    {
        if (Lib.Commands.FirstOrDefault(c => c.Id == Str(args, "commandId") && c.To == _devices[me].Id) is not { } command) return Fail("notFound", "No such command for this device.");
        if (args["result"] is not { } result) return Fail("invalidArgument", "result");
        if (result["message"] is not null) return Fail("invalidArgument", "Object contains extra field `message`");
        if (result["content"] is { IsNull: false } content && !Accepts(content, true)) return Fail("forbidden", "This data is sealed with a key your account doesn't use.");
        command.Result ??= result;
        return Now();
    }

    /// <summary>Every content row the server holds, as JSON: what a dump of its tables would show.</summary>
    public string ContentDump
    {
        get
        {
            lock (_lock)
                return string.Join("\n", _libraries.Values.Select(l => ConvexValue.Object(
                    ("playback", ConvexValue.Array(l.Playback.Values)), ("queues", ConvexValue.Array(l.Queues.Values)), ("settings", ConvexValue.Array(l.Settings.Values)),
                    ("commands", ConvexValue.Array(l.Commands.Select(c => ConvexValue.Object(("command", c.Command), ("result", c.Result ?? ConvexValue.Null))))))
                    .JsonString()));
        }
    }

    private ConvexValue Rotate(ConvexValue args, int me)
    {
        if (_devices[me].State is not State.Holder) return Fail("forbidden", "not a holder");
        if (Str(args, "fromKeyId") is not { } from || Str(args, "keyId") is not { } to) return Fail("invalidArgument", "keys");
        Learn(_devices[me].Token, from, to);
        if (Lib.KeyId == to && !Lib.RotationNeeded) return Ok(ConvexValue.Object(("keyRevision", ConvexValue.Float64(Lib.KeyRevision)), ("serverNow", ConvexValue.Float64(Tick()))));
        if (Lib.KeyId != from) return Fail("conflict", "Your account's key changed.");
        if (to == from || Lib.Retired.Contains(to)) return Fail("forbidden", "Use a new key.");
        if (args["wraps"]?.ArrayValue is not { } wraps || args["vault"]?.ArrayValue is not { } reseal) return Fail("invalidArgument", "lists");
        var others = Mine.Where(i => i != me && _devices[i].State is State.Holder).ToList();
        var wrapped = wraps.Where(w => Str(w, "deviceId") is not null).GroupBy(w => Str(w, "deviceId")!).ToDictionary(g => g.Key, g => Str(g.First(), "wrapped") ?? "");
        if (wrapped.Count != others.Count || !others.All(i => wrapped.ContainsKey(_devices[i].Id))) return Fail("conflict", "Your devices changed.");
        var sealedRows = Lib.Vault.Where(r => r.Sealed is not null).ToList();
        if (reseal.Count != sealedRows.Count) return Fail("conflict", "Your sign-ins changed.");
        // Every settings row, re-sealed under the new key (null: deleted), at the time it was read.
        var resealedSettings = args["settings"]?.ArrayValue ?? [];
        if (resealedSettings.Count != Lib.Settings.Count
            || !resealedSettings.All(r => Str(r, "key") is { } key && Lib.Settings.TryGetValue(key, out var row) && row["updatedAt"]?.DoubleValue == r["baseUpdatedAt"]?.DoubleValue))
            return Fail("conflict", "Your settings changed.");
        if (resealedSettings.Any(r => r["value"] is { IsNull: false } v && Str(v, "keyId") != to)) return Fail("forbidden", "Seal settings with the new key.");
        foreach (var r in reseal)
            if (sealedRows.FirstOrDefault(row => row.Provider == Str(r, "provider")) is not { } row || Int(r, "baseRevision") != row.Revision)
                return Fail("conflict", "Your sign-ins changed.");
        foreach (var r in reseal)
        {
            var provider = Str(r, "provider")!;
            var row = Lib.Vault.First(x => x.Provider == provider);
            var sealedText = Str(r, "sealed");
            StoreRow(new Row(provider, sealedText, false, sealedText is null ? new string('0', 32) : to, row.Revision + 1, Tick(), _devices[me].Id));
        }
        foreach (var i in others)
        {
            if (_devices[i].State is State.Holder { Rekey: not null }) _devices[i].State = new State.Requested();
            else
            {
                _devices[i].State = new State.Holder(new Rekey(to, from, wrapped[_devices[i].Id], _devices[me].Id));
                _devices[i].ExposedKeyId = to;
            }
        }
        foreach (var i in Mine) if (_devices[i].State is State.Granted) _devices[i].State = new State.Requested();
        foreach (var r in resealedSettings)
        {
            var key = Str(r, "key")!;
            if (r["value"] is not { IsNull: false } value) { Lib.Settings.Remove(key); continue; }
            Lib.Settings[key] = ConvexValue.Object(("key", ConvexValue.String(key)), ("value", value), ("updatedAt", ConvexValue.Float64(Tick())),
                                                   ("updatedBy", ConvexValue.String(_devices[me].Id)));
        }
        Lib.PreviousKey = from;
        _devices[me].ExposedKeyId = to;
        Lib.Retired.Add(from);
        Lib.KeyId = to;
        Lib.RotationNeeded = false;
        Bump();
        return Ok(ConvexValue.Object(("keyRevision", ConvexValue.Float64(Lib.KeyRevision)), ("serverNow", ConvexValue.Float64(Tick()))));
    }
}
