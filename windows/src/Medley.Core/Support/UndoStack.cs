namespace Medley.Core.Support;

/// <summary>
/// A small stand-in for Foundation's <c>UndoManager</c>, enough for the player's "Clear Up Next" and "Remove from Queue":
/// an action registered while undoing goes on the redo stack, one registered while redoing (or normally) on the undo
/// stack, and a normal registration clears redo. One registration is one step (no grouping).
/// </summary>
public sealed class UndoStack
{
    private sealed record Step(string ActionName, Action Run);

    private readonly List<Step> _undo = [];
    private readonly List<Step> _redo = [];
    private bool _undoing;
    private bool _redoing;

    public bool CanUndo => _undo.Count > 0;
    public bool CanRedo => _redo.Count > 0;
    public string? UndoActionName => _undo.Count > 0 ? _undo[^1].ActionName : null;
    public string? RedoActionName => _redo.Count > 0 ? _redo[^1].ActionName : null;

    /// <summary>Raised after any change, for menus and buttons.</summary>
    public event EventHandler? Changed;

    public void Register(string actionName, Action undo)
    {
        var step = new Step(actionName, undo);
        if (_undoing) _redo.Add(step);
        else
        {
            _undo.Add(step);
            if (!_redoing) _redo.Clear();
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Renames the step registered last on the stack being filled, as <c>setActionName</c> does.</summary>
    public void SetActionName(string name)
    {
        var stack = _undoing ? _redo : _undo;
        if (stack.Count > 0) stack[^1] = stack[^1] with { ActionName = name };
    }

    public void Undo()
    {
        if (_undo.Count == 0) return;
        var step = _undo[^1];
        _undo.RemoveAt(_undo.Count - 1);
        _undoing = true;
        try { step.Run(); }
        finally { _undoing = false; }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void Redo()
    {
        if (_redo.Count == 0) return;
        var step = _redo[^1];
        _redo.RemoveAt(_redo.Count - 1);
        _redoing = true;
        try { step.Run(); }
        finally { _redoing = false; }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void Clear()
    {
        _undo.Clear();
        _redo.Clear();
        Changed?.Invoke(this, EventArgs.Empty);
    }
}
