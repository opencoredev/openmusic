using System.Collections.Concurrent;
using System.Runtime.CompilerServices;

namespace OpenMusic.Sync;

/// <summary>
/// The thread sync state lives on: the C# stand-in for the Swift client's <c>@MainActor</c>. Every public method of
/// SyncService, AccountService, SignInSync, SettingsSync and SyncCoordinator dispatches to it before it reads or changes
/// state (<see cref="Switch"/>, <see cref="Perform"/>, <see cref="Read{T}"/>), and the code that touches state checks it
/// (<see cref="AssertCurrent"/>, debug builds), so state is only ever touched from one thread and <c>await</c>s resume in
/// order on it. Published properties are immutable snapshots, replaced (never changed) on the actor, so reading one from
/// another thread sees one whole value. Events are raised on it; the app marshals them to its UI thread (or passes its
/// own UI <see cref="SynchronizationContext"/> to <see cref="SyncActor(SynchronizationContext)"/>, and events arrive there).
/// </summary>
public sealed class SyncActor
{
    public SynchronizationContext Context { get; }

    public SyncActor(SynchronizationContext context) => Context = context;

    /// <summary>A dedicated background thread with its own context.</summary>
    public static SyncActor CreateDedicated(string name = "OpenMusic sync")
    {
        var context = new DedicatedThreadContext(name);
        return new SyncActor(context);
    }

    public bool IsCurrent => SynchronizationContext.Current == Context;

    /// <summary><c>await actor.Switch()</c> continues on the actor (at once when already on it).</summary>
    public SwitchAwaitable Switch() => new(this);

    public void Post(Action action) => Context.Post(_ => action(), null);

    /// <summary>
    /// The dispatch for a public method that returns nothing: runs <paramref name="action"/> at once when already on the
    /// actor, else posts it there. It never runs beside actor work.
    /// </summary>
    public void Perform(Action action)
    {
        if (IsCurrent) action();
        else Post(action);
    }

    /// <summary>
    /// The dispatch for a public synchronous read of actor state: at once on the actor, else on the actor while the caller
    /// waits (<see cref="SynchronizationContext.Send"/>). The actor never blocks on another thread, so this can't deadlock.
    /// </summary>
    public T Read<T>(Func<T> read)
    {
        if (IsCurrent || t_setup > 0) return read();
        T result = default!;
        Context.Send(_ => result = read(), null);
        return result;
    }

    // MARK: Assertions (debug builds)

    [ThreadStatic] private static int t_setup;
    [ThreadStatic] private static bool t_expected;
    private static int s_violations;

    /// <summary>Tests of the assertion itself: on this thread a violation still throws but isn't counted.</summary>
    internal static void ExpectViolation(bool expected) => t_expected = expected;

    /// <summary>How many times actor state was touched off the actor (debug builds; tests assert it stays 0).</summary>
    internal static int Violations => Volatile.Read(ref s_violations);

    /// <summary>
    /// Debug builds: throws when called off the actor. Every method that reads or changes actor-owned state calls it, so a
    /// public entry point that forgot to dispatch fails the first test that calls it from another thread.
    /// </summary>
    [System.Diagnostics.Conditional("DEBUG")]
    public void AssertCurrent([CallerMemberName] string? caller = null)
    {
        if (IsCurrent || t_setup > 0) return;
        if (!t_expected) Interlocked.Increment(ref s_violations);
        throw new InvalidOperationException($"{caller} touched sync state off the sync actor");
    }

    /// <summary>
    /// For constructors: the object isn't shared yet, so its state may be set up on the creating thread. Dispose to end.
    /// </summary>
    internal static SetupScope Setup()
    {
        t_setup++;
        return default;
    }

    internal readonly struct SetupScope : IDisposable
    {
        public void Dispose() => t_setup--;
    }

    /// <summary>Runs <paramref name="body"/> on the actor and returns its result.</summary>
    public async Task<T> Run<T>(Func<T> body)
    {
        await Switch();
        return body();
    }

    public async Task Run(Action body)
    {
        await Switch();
        body();
    }

    public async Task<T> RunAsync<T>(Func<Task<T>> body)
    {
        await Switch();
        return await body();
    }

    public async Task RunAsync(Func<Task> body)
    {
        await Switch();
        await body();
    }

    public readonly struct SwitchAwaitable(SyncActor actor) : INotifyCompletion
    {
        public SwitchAwaitable GetAwaiter() => this;
        public bool IsCompleted => actor.IsCurrent;
        public void OnCompleted(Action continuation) => actor.Context.Post(_ => continuation(), null);
        public void GetResult() { }
    }

    private sealed class DedicatedThreadContext : SynchronizationContext
    {
        private readonly BlockingCollection<(SendOrPostCallback, object?)> _queue = new();
        private readonly Thread _thread;

        public DedicatedThreadContext(string name)
        {
            _thread = new Thread(Loop) { IsBackground = true, Name = name };
            _thread.Start();
        }

        private void Loop()
        {
            SetSynchronizationContext(this);
            foreach (var (callback, state) in _queue.GetConsumingEnumerable())
            {
                try { callback(state); }
                catch (Exception e) { Console.Error.WriteLine($"[sync actor] unhandled: {e}"); }
            }
        }

        public override void Post(SendOrPostCallback d, object? state) => _queue.Add((d, state));

        public override void Send(SendOrPostCallback d, object? state)
        {
            if (Thread.CurrentThread == _thread) { d(state); return; }
            using var done = new ManualResetEventSlim();
            Exception? error = null;
            _queue.Add((s => { try { d(s); } catch (Exception e) { error = e; } finally { done.Set(); } }, state));
            done.Wait();
            if (error is not null) throw error;
        }

        public override SynchronizationContext CreateCopy() => this;
    }
}
