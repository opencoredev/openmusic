namespace Medley.Core;

/// <summary>A cancellable one-shot action created by an <see cref="IPlaybackScheduler"/>.</summary>
public sealed class ScheduledAction
{
    private Action? _onCancel;

    public ScheduledAction(Action onCancel) => _onCancel = onCancel;

    public void Cancel()
    {
        _onCancel?.Invoke();
        _onCancel = null;
    }
}

/// <summary>Clock and one-shot timers for the player (sleep timer, persistence debounce). Injected so tests can drive
/// time by hand. Nothing here polls: every action is a single deadline.</summary>
public interface IPlaybackScheduler
{
    DateTimeOffset Now { get; }
    /// <summary>Runs <paramref name="action"/> once on the calling thread's synchronization context,
    /// <paramref name="delaySeconds"/> from now, unless cancelled first.</summary>
    ScheduledAction Schedule(double delaySeconds, Action action);
}

/// <summary>The production scheduler: wall clock plus one <see cref="Task.Delay(TimeSpan, CancellationToken)"/> per action,
/// resumed on the caller's synchronization context (the UI thread).</summary>
public sealed class SystemScheduler : IPlaybackScheduler
{
    public DateTimeOffset Now => DateTimeOffset.UtcNow;

    public ScheduledAction Schedule(double delaySeconds, Action action)
    {
        var cts = new CancellationTokenSource();
        _ = Run();
        return new ScheduledAction(cts.Cancel);

        async Task Run()
        {
            try
            {
                await Task.Delay(TimeSpan.FromSeconds(Math.Max(0, delaySeconds)), cts.Token);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            if (!cts.IsCancellationRequested) action();
        }
    }
}
