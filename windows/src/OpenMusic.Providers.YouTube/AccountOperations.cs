namespace OpenMusic.Providers.YouTube;

/// <summary>
/// The serial executor every account operation of a <see cref="YouTubeMusicProvider"/> runs on (Swift:
/// <c>AccountOperations</c> in the sync layer): restore, sign-in, sign-out, a transfer import or export, saving rotated
/// cookies. One operation runs at a time, awaits included, in the order they were enqueued, so none ever acts on another's
/// half-done state.
/// </summary>
/// <remarks>
/// <para>A sign-in or sign-out supersedes everything older: queued operations never run (they end with
/// <see cref="OperationCanceledException"/>), and the running one is cancelled (<see cref="Ticket.Token"/>) and abandoned,
/// so the next one starts even when it is stuck in an await that ignores cancellation. A superseded operation's
/// <see cref="Ticket.IsCurrent"/> is false from then on, and the provider refuses its commit, so it changes nothing after
/// it resumes. A caller's own cancellation supersedes just its operation.</para>
/// <para>Immune operations are never superseded or cancelled: a sign-out (so a sign-in queued behind it can't undo it),
/// and the short synchronous reads and rotation saves.</para>
/// <para>Nothing inside an operation may wait for another operation: it would wait for itself.</para>
/// </remarks>
internal sealed class AccountOperations
{
    internal enum Kind
    {
        /// <summary>Runs in order; superseded by a later sign-in or sign-out.</summary>
        Ordinary,
        /// <summary>A sign-in: supersedes everything older that isn't immune, and can itself be superseded.</summary>
        Supersedes,
        /// <summary>A sign-out: supersedes everything older that isn't immune, and is never superseded or cancelled.</summary>
        SupersedesImmune,
        /// <summary>Runs in order and is never superseded or cancelled. Only for short synchronous work.</summary>
        Immune,
    }

    /// <summary>One enqueued operation.</summary>
    internal sealed class Ticket
    {
        readonly AccountOperations _owner;
        internal readonly CancellationTokenSource Cancellation = new();
        internal Func<Task> Execute = () => Task.CompletedTask;
        internal Action Abort = () => { };
        /// <summary>The caller's cancellation, which supersedes this ticket. Under the owner's gate, like the flags.</summary>
        internal CancellationTokenRegistration Registration;
        internal bool Stale;
        internal bool Ended;

        internal Ticket(AccountOperations owner, string name, bool immune)
        {
            _owner = owner;
            Name = name;
            Immune = immune;
        }

        public string Name { get; }
        public bool Immune { get; }

        /// <summary>Cancelled when the operation is superseded.</summary>
        public CancellationToken Token => Cancellation.Token;

        /// <summary>False once superseded (or cancelled): from then on the operation must change nothing.</summary>
        public bool IsCurrent
        {
            get { lock (_owner._gate) return !Stale; }
        }

        public override string ToString() => $"{Name}{(IsCurrent ? "" : " (superseded)")}";
    }

    /// <summary>Tickets just marked stale, to cancel once every lock is released.</summary>
    internal readonly struct Retirement(List<(Ticket Ticket, bool Queued)> tickets, Ticket? next)
    {
        internal List<(Ticket Ticket, bool Queued)> Tickets { get; } = tickets;
        internal Ticket? Next { get; } = next;
    }

    readonly Lock _gate = new();
    readonly LinkedList<Ticket> _queue = new();
    Ticket? _running;

    /// <summary>Enqueues <paramref name="body"/>. Its task ends when the body does, or cancelled if it was superseded before it started.</summary>
    public Task<T> RunAsync<T>(string name, Kind kind, Func<Ticket, Task<T>> body, CancellationToken ct = default)
    {
        var done = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        var ticket = new Ticket(this, name, kind is Kind.Immune or Kind.SupersedesImmune);
        ticket.Execute = async () =>
        {
            try { done.TrySetResult(await body(ticket).ConfigureAwait(false)); }
            catch (OperationCanceledException e) { done.TrySetCanceled(e.CancellationToken); }
            catch (Exception e) { done.TrySetException(e); }
        };
        ticket.Abort = () => done.TrySetCanceled();
        Retirement retirement;
        lock (_gate)
        {
            var stale = kind is Kind.Supersedes or Kind.SupersedesImmune ? StaleLocked(_ => true) : [];
            _queue.AddLast(ticket);
            retirement = new Retirement(stale, NextLocked());
        }
        Complete(retirement);
        if (ct.CanBeCanceled && !ticket.Immune)
        {
            var registration = ct.Register(() => Cancel(t => t == ticket));
            bool ended;
            lock (_gate)
            {
                ticket.Registration = registration;
                ended = ticket.Ended;
            }
            if (ended) registration.Dispose();
        }
        return done.Task;
    }

    /// <summary>Supersedes the operations (queued or running) <paramref name="match"/> picks. Never an immune one.</summary>
    public void Cancel(Func<Ticket, bool> match) => Complete(Stale(match));

    /// <summary>
    /// The marking half of <see cref="Cancel"/>, for a caller that must do it atomically with its own state (under its
    /// lock): pass the result to <see cref="Complete"/> after releasing that lock.
    /// </summary>
    public Retirement Stale(Func<Ticket, bool> match)
    {
        lock (_gate) return new Retirement(StaleLocked(match), NextLocked());
    }

    /// <summary>Cancels what <see cref="Stale"/> marked and starts the next operation. Outside every lock: cancellation runs callbacks.</summary>
    public void Complete(Retirement retirement)
    {
        foreach (var (ticket, queued) in retirement.Tickets)
        {
            if (queued)
            {
                ticket.Abort();
                End(ticket);
            }
            try { ticket.Cancellation.Cancel(); }
            catch (AggregateException) { } // a registration's callback threw; the ticket is stale either way
        }
        if (retirement.Next != null) Launch(retirement.Next);
    }

    List<(Ticket, bool)> StaleLocked(Func<Ticket, bool> match)
    {
        var stale = new List<(Ticket, bool)>();
        for (var node = _queue.First; node != null;)
        {
            var next = node.Next;
            if (!node.Value.Immune && match(node.Value))
            {
                node.Value.Stale = true;
                _queue.Remove(node);
                stale.Add((node.Value, true));
            }
            node = next;
        }
        if (_running is { Immune: false } running && match(running))
        {
            running.Stale = true;
            _running = null; // abandoned: the next operation doesn't wait for it
            stale.Add((running, false));
        }
        return stale;
    }

    Ticket? NextLocked()
    {
        if (_running != null || _queue.First is not { } first) return null;
        _queue.RemoveFirst();
        _running = first.Value;
        return first.Value;
    }

    void Launch(Ticket ticket) => _ = Task.Run(async () =>
    {
        try { await ticket.Execute().ConfigureAwait(false); }
        finally { Finished(ticket); }
    });

    void Finished(Ticket ticket)
    {
        Ticket? next;
        lock (_gate)
        {
            if (_running == ticket) _running = null;
            next = NextLocked();
        }
        End(ticket);
        if (next != null) Launch(next);
    }

    void End(Ticket ticket)
    {
        CancellationTokenRegistration registration;
        lock (_gate)
        {
            ticket.Ended = true;
            registration = ticket.Registration;
            ticket.Registration = default;
        }
        registration.Dispose();
    }
}
