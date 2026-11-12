using System.Text;

namespace Medley.Core.Mock;

/// <summary>Small deterministic generator (SplitMix64), bit for bit the Swift mock's <c>SeededRandom</c>, so the C# mock
/// catalogs, lyrics and art match the Mac and iOS apps' exactly.</summary>
public struct SeededRandom
{
    private ulong _state;

    public SeededRandom(ulong seed) => _state = seed;

    public ulong Next()
    {
        unchecked
        {
            _state += 0x9E3779B97F4A7C15UL;
            var z = _state;
            z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL;
            z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL;
            return z ^ (z >> 31);
        }
    }

    /// <summary>0..&lt;1</summary>
    public double Unit() => (Next() >> 11) / (double)(1UL << 53);

    /// <summary>The mock's own <c>int(_:)</c>: <c>lower + next() % count</c>.</summary>
    public int Int(int lowerBound, int upperBound) => lowerBound + (int)(Next() % (ulong)(upperBound - lowerBound));

    /// <summary>Swift's <c>RandomNumberGenerator.next(upperBound:)</c> (Lemire's multiply-shift with rejection).</summary>
    public ulong NextBelow(ulong upperBound)
    {
        var random = Next();
        var high = Math.BigMul(random, upperBound, out var low);
        if (low < upperBound)
        {
            var t = unchecked(0UL - upperBound) % upperBound;
            while (low < t)
            {
                random = Next();
                high = Math.BigMul(random, upperBound, out low);
            }
        }
        return high;
    }

    /// <summary>Swift's <c>shuffle(using:)</c> (Fisher–Yates from the front with <c>Int.random(in: 0..&lt;amount)</c>).</summary>
    public void Shuffle<T>(IList<T> list)
    {
        if (list.Count <= 1) return;
        var amount = list.Count;
        var current = 0;
        while (amount > 1)
        {
            var random = (int)NextBelow((ulong)amount);
            amount -= 1;
            (list[current], list[current + random]) = (list[current + random], list[current]);
            current += 1;
        }
    }

    /// <summary>Swift's <c>shuffled(using:)</c>.</summary>
    public List<T> Shuffled<T>(IEnumerable<T> items)
    {
        var list = items.ToList();
        Shuffle(list);
        return list;
    }

    /// <summary>FNV-1a over the UTF-8 bytes, as the Swift mock seeds its generators.</summary>
    public static ulong Fnv1a(string s)
    {
        var h = 0xcbf29ce484222325UL;
        foreach (var b in Encoding.UTF8.GetBytes(s))
        {
            h ^= b;
            h = unchecked(h * 0x100000001b3UL);
        }
        return h;
    }
}
