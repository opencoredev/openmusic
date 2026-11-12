using System.Runtime.ExceptionServices;

namespace Medley.Sync;

/// <summary>
/// The one serial executor for a SyncService's account and key operations (port of <c>AccountOperations.swift</c>):
/// sign-in, sign-out, registration, applying a device list, claims, releases, rotations, grants and their answers, Ask
/// Again, removing a device. An operation runs to completion, awaits included, before the next one starts.
/// <para>
/// Every operation holds a <see cref="Ticket"/> with the epoch it was enqueued in. A sign-in, a sign-out, forget and stop
/// start a new epoch (<see cref="Supersede"/>): older operations that haven't run never run their bodies, and the running
/// one is cancelled (its calls end with <see cref="OperationCanceledException"/>) and abandoned. A sign-out is immune.
/// </para>
/// Rules inside an operation: after every await, check the ticket before touching state; never wait for another
/// operation (a nested <see cref="Run{T}"/> runs inline); follow-up work is <see cref="Enqueue"/>d.
/// Use only on the <see cref="SyncActor"/>.
/// </summary>
internal sealed class AccountOperations
{
    /// <summary>What an operation was enqueued for. Stops being valid when a newer epoch starts, unless immune.</summary>
    public readonly record struct Ticket(int Epoch, bool Immune, CancellationToken Token)
    {
        /// <summary>Throws <see cref="OperationCanceledException"/> once this operation was superseded (or cancelled).</summary>
        public void Check(AccountOperations queue)
        {
            if (Immune) return;
            if (Epoch != queue.Epoch || Token.IsCancellationRequested) throw new OperationCanceledException(Token);
        }

        public bool IsValid(AccountOperations queue) => Immune || (Epoch == queue.Epoch && !Token.IsCancellationRequested);
    }

    public enum Dedup { Started, Finished }

    public int Epoch { get; private set; }
    private Latch? _tail;
    private readonly Dictionary<int, Latch> _latches = new();
    private (int Serial, bool Immune, CancellationToken Token)? _running;
    private readonly Dictionary<int, CancellationTokenSource> _tasks = new();
    private int _serial;
    private readonly HashSet<string> _pendingIds = new();
    public int Completed { get; private set; }

    /// <summary>The serial of the operation the caller runs inside (flows with the async context, like Swift's TaskLocal).</summary>
    internal static readonly AsyncLocal<int?> Current = new();

    public Ticket NewTicket() => new(Epoch, false, CancellationToken.None);

    /// <summary>
    /// Starts a new epoch and returns its ticket: everything enqueued before (except a sign-out) won't run, and the running
    /// operation, unless it is a sign-out, is cancelled and abandoned (the queue goes on without waiting for it to unwind).
    /// </summary>
    public Ticket Supersede(bool immune = false)
    {
        Epoch++;
        if (_running is { } running && !running.Immune)
        {
            if (_tasks.TryGetValue(running.Serial, out var cts)) cts.Cancel();
            if (_latches.TryGetValue(running.Serial, out var latch)) latch.Open();
            _running = null;
        }
        return new Ticket(Epoch, immune, CancellationToken.None);
    }

    /// <summary>Whether an operation with this id is queued or running.</summary>
    public bool IsPending(string id) => _pendingIds.Contains(id);

    private bool IsInsideRunning => Current.Value is { } current && _running is { } running && current == running.Serial;

    /// <summary>
    /// Runs <paramref name="body"/> as an operation once every earlier one finished, and returns its result. From inside
    /// the running operation it runs at once, as part of it.
    /// </summary>
    public async Task<T> Run<T>(Ticket? ticket, Func<Ticket, Task<T>> body)
    {
        var t = ticket ?? NewTicket();
        if (IsInsideRunning) return await body(t with { Token = _running!.Value.Token });
        var done = false;
        T result = default!;
        Exception? error = null;
        await Schedule(t, async tk =>
        {
            try { result = await body(tk); done = true; }
            catch (Exception e) { error = e; }
        }, null);
        if (error is not null) ExceptionDispatchInfo.Capture(error).Throw();
        if (!done) throw new OperationCanceledException();
        return result;
    }

    public Task Run(Ticket? ticket, Func<Ticket, Task> body) => Run<bool>(ticket, async t => { await body(t); return true; });

    /// <summary>
    /// Queues <paramref name="body"/> without waiting for it. With an id, nothing is queued while an operation with the same
    /// id is still queued or running (<see cref="Dedup.Finished"/>), or still queued (<see cref="Dedup.Started"/>).
    /// </summary>
    public void Enqueue(string? id, Func<Ticket, Task> body, Dedup until = Dedup.Finished)
    {
        if (id is not null && !_pendingIds.Add(id)) return;
        _ = Schedule(NewTicket(), async t =>
        {
            if (id is not null && until == Dedup.Started) _pendingIds.Remove(id);
            try { await body(t); }
            catch (OperationCanceledException) { }
            catch (Exception e) { Console.Error.WriteLine($"[sync] operation {id ?? "?"} failed: {e.Message}"); }
            if (id is not null && until == Dedup.Finished) _pendingIds.Remove(id);
        }, () => { if (id is not null) _pendingIds.Remove(id); });
    }

    public void Enqueue(string? id, Action<Ticket> body, Dedup until = Dedup.Finished) =>
        Enqueue(id, t => { body(t); return Task.CompletedTask; }, until);

    /// <summary>An operation that never awaits (Codes Match): runs at once when the queue is idle, else is queued.</summary>
    public void Perform(Action body)
    {
        if (_running is null && _tasks.Count == 0) body();
        else Enqueue(null, _ => body());
    }

    private Task Schedule(Ticket ticket, Func<Ticket, Task> body, Action? skipped)
    {
        var previous = _tail;
        _serial++;
        var number = _serial;
        var latch = new Latch();
        var cts = new CancellationTokenSource();
        var t = ticket with { Token = cts.Token };
        _tasks[number] = cts;
        _latches[number] = latch;
        _tail = latch;
        return RunScheduled();

        async Task RunScheduled()
        {
            Current.Value = null;   // a new operation doesn't inherit the one it was enqueued from
            await Task.Yield();     // never starts before Schedule returns
            if (previous is not null) await previous.Wait();
            try
            {
                if (!t.IsValid(this)) { skipped?.Invoke(); return; }
                _running = (number, t.Immune, cts.Token);
                Current.Value = number;
                await body(t);
                Completed++;
            }
            finally
            {
                _tasks.Remove(number);
                _latches.Remove(number);
                if (_running?.Serial == number) _running = null;
                latch.Open();
            }
        }
    }

    /// <summary>Waits until everything queued now has run (tests).</summary>
    public async Task Drain()
    {
        while (_tail is { } tail)
        {
            await tail.Wait();
            if (ReferenceEquals(_tail, tail)) return;
        }
    }

    private sealed class Latch
    {
        private readonly TaskCompletionSource _tcs = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Task Wait() => _tcs.Task;
        public void Open() => _tcs.TrySetResult();
    }
}
