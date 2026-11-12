using System.Collections.Concurrent;

namespace OpenMusic.Core.Threading;

/// <summary>
/// A single-threaded <see cref="SynchronizationContext"/>: the stand-in for Swift's main actor outside a UI app.
/// <see cref="PlayerController"/> and providers expect to be driven from one thread with a context, so their
/// <c>await</c>s resume in order on it. The WinUI app has its own (the DispatcherQueue's); tests, probes and console
/// tools run their work through <see cref="Run(Func{Task})"/>.
/// </summary>
public sealed class MainThreadContext : SynchronizationContext
{
    private readonly BlockingCollection<(SendOrPostCallback Callback, object? State)> _queue = new();
    private readonly int _threadId = Environment.CurrentManagedThreadId;

    private MainThreadContext() { }

    public override void Post(SendOrPostCallback d, object? state)
    {
        try
        {
            _queue.Add((d, state));
        }
        catch (InvalidOperationException)
        {
            // Completed: work posted after the run ended (a late timer) is dropped, as a main actor that's gone would.
        }
    }

    public override void Send(SendOrPostCallback d, object? state)
    {
        if (Environment.CurrentManagedThreadId == _threadId) d(state);
        else throw new NotSupportedException("Send from another thread");
    }

    public override SynchronizationContext CreateCopy() => this;

    /// <summary>Runs <paramref name="body"/> on the current thread with a fresh context, pumping posted work until the
    /// returned task completes. Rethrows its exception.</summary>
    public static void Run(Func<Task> body)
    {
        var previous = Current;
        var context = new MainThreadContext();
        SetSynchronizationContext(context);
        try
        {
            var task = body();
            task.ContinueWith(_ => context._queue.CompleteAdding(), TaskScheduler.Default);
            foreach (var (callback, state) in context._queue.GetConsumingEnumerable()) callback(state);
            task.GetAwaiter().GetResult();
        }
        finally
        {
            SetSynchronizationContext(previous);
        }
    }

    public static T Run<T>(Func<Task<T>> body)
    {
        T result = default!;
        // A block body, so the lambda is a Func<Task> and binds to Run(Func<Task>). The expression form
        // `async () => result = await body()` returns Task<T> and binds back to this overload, recursing forever.
        Run(async () => { result = await body(); });
        return result;
    }
}
