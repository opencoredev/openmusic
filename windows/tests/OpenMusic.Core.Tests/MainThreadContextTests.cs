using OpenMusic.Core.Threading;

namespace OpenMusic.Core.Tests;

public class MainThreadContextTests
{
    [Fact]
    public void RunWithResultReturnsTheValue()
    {
        // Regression: Run<T> used to bind its own inner call back to Run<T> and overflow the stack.
        var value = MainThreadContext.Run(async () =>
        {
            await Task.Yield();
            return 42;
        });
        Assert.Equal(42, value);
    }

    [Fact]
    public void ContinuationsResumeOnTheSameThread()
    {
        var threads = MainThreadContext.Run(async () =>
        {
            var before = Environment.CurrentManagedThreadId;
            await Task.Delay(10);
            await Task.Yield();
            return (before, after: Environment.CurrentManagedThreadId, context: SynchronizationContext.Current);
        });
        Assert.Equal(threads.before, threads.after);
        Assert.IsType<MainThreadContext>(threads.context);
    }

    [Fact]
    public void ExceptionsPropagate() =>
        Assert.Throws<InvalidOperationException>(() => MainThreadContext.Run<int>(async () =>
        {
            await Task.Yield();
            throw new InvalidOperationException("boom");
        }));
}
