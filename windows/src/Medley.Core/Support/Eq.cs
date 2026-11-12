using System.Collections.ObjectModel;

namespace Medley.Core.Support;

/// <summary>Value equality helpers for records that hold lists and dictionaries (Swift structs compare them by value).</summary>
internal static class Eq
{
    public static readonly IReadOnlyDictionary<string, string> EmptyExtra = ReadOnlyDictionary<string, string>.Empty;

    public static bool Dict(IReadOnlyDictionary<string, string> a, IReadOnlyDictionary<string, string> b)
    {
        if (ReferenceEquals(a, b)) return true;
        if (a.Count != b.Count) return false;
        foreach (var (k, v) in a)
        {
            if (!b.TryGetValue(k, out var w) || v != w) return false;
        }
        return true;
    }

    public static bool SeqOrNull<T>(IReadOnlyList<T>? a, IReadOnlyList<T>? b) =>
        a is null ? b is null : b is not null && a.SequenceEqual(b);

    public static int SeqHash<T>(IReadOnlyList<T> items)
    {
        var h = new HashCode();
        foreach (var i in items) h.Add(i);
        return h.ToHashCode();
    }
}
