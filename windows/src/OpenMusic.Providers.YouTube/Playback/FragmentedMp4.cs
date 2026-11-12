using System.Buffers.Binary;

namespace OpenMusic.Providers.YouTube.Playback;

/// <summary>
/// Turns YouTube's DASH audio (itag 140: a fragmented MP4, <c>ftyp moov sidx (moof mdat)…</c>) into an ordinary MP4 that
/// players without fragmented-MP4 support can open and seek, without downloading the audio first.
/// <para>Windows' Media Foundation byte-stream source reads the empty sample table in the fragmented file's <c>moov</c>
/// and ends at once. So: read the head (<c>ftyp</c>, <c>moov</c>, <c>sidx</c>), then each fragment's <c>moof</c> (small,
/// a few kB, fetched in parallel), and build a <c>moov</c> whose <c>stts/stsc/stsz/stco</c> list every sample. The flat
/// file is that new head followed by one <c>mdat</c> holding every fragment's sample data in order; <see cref="Layout.Map"/>
/// gives, for any byte of it, where those bytes are in the original file, so the audio itself is still read from the
/// network as it plays.</para>
/// Pure and thread-safe; the app does the HTTP.
/// </summary>
public static class FragmentedMp4
{
    /// <summary>One fragment from the <c>sidx</c>: where its <c>moof</c> starts and how many bytes moof+mdat take.</summary>
    public readonly record struct FragmentRef(long Offset, long Size, long Duration);

    /// <summary>What the head of the file says.</summary>
    public sealed record Head(byte[] Ftyp, byte[] Moov, uint Timescale, IReadOnlyList<FragmentRef> Fragments)
    {
        /// <summary>The last byte the head occupies (exclusive): everything up to the first fragment.</summary>
        public long FirstFragment => Fragments.Count > 0 ? Fragments[0].Offset : 0;
    }

    /// <summary>One fragment's samples: their sizes and durations, and where their data starts in the original file.</summary>
    public sealed record Fragment(long DataOffset, uint[] Sizes, uint[] Durations)
    {
        public long DataLength => Sizes.Sum(s => (long)s);
    }

    /// <summary>A run of the flat file's bytes that comes from the original file.</summary>
    public readonly record struct Segment(long FlatOffset, long SourceOffset, long Length);

    /// <summary>The flat file: <see cref="Header"/> (ftyp, moov, the mdat box header) then the sample data.</summary>
    public sealed class Layout(byte[] header, IReadOnlyList<Segment> segments, long length, double seconds)
    {
        public byte[] Header { get; } = header;
        public IReadOnlyList<Segment> Segments { get; } = segments;
        public long Length { get; } = length;
        public double Seconds { get; } = seconds;

        /// <summary>For a flat offset at or after the header: the segment it's in.</summary>
        public int SegmentIndex(long flatOffset)
        {
            int lo = 0, hi = Segments.Count - 1;
            while (lo <= hi)
            {
                var mid = (lo + hi) >>> 1;
                var s = Segments[mid];
                if (flatOffset < s.FlatOffset) hi = mid - 1;
                else if (flatOffset >= s.FlatOffset + s.Length) lo = mid + 1;
                else return mid;
            }
            return -1;
        }
    }

    // MARK: Head

    /// <summary>Reads ftyp, moov and sidx from the first bytes of the file. Null when they aren't all there yet
    /// (<paramref name="needed"/> then says how many bytes would be) or the file isn't a fragmented MP4 with an index.</summary>
    public static Head? ParseHead(ReadOnlySpan<byte> data, out long needed)
    {
        needed = 0;
        byte[]? ftyp = null, moov = null;
        long pos = 0;
        while (pos + 8 <= data.Length)
        {
            var (size, type, header) = BoxAt(data, pos);
            if (size < 8) return null;
            if (pos + size > data.Length)
            {
                needed = pos + size;
                return null;
            }
            var box = data.Slice((int)pos, (int)size);
            switch (type)
            {
                case "ftyp": ftyp = box.ToArray(); break;
                case "moov": moov = box.ToArray(); break;
                case "sidx":
                    if (ftyp is null || moov is null) return null;
                    var refs = ParseSidx(box[header..], pos + size, out var timescale);
                    return refs is null ? null : new Head(ftyp, moov, timescale, refs);
                case "moof":
                    return null; // fragments without an index: not supported
            }
            pos += size;
        }
        needed = Math.Max(pos + 8, data.Length + 64 * 1024);
        return null;
    }

    static List<FragmentRef>? ParseSidx(ReadOnlySpan<byte> body, long end, out uint timescale)
    {
        var version = body[0];
        var p = 4 + 4; // version/flags, reference_ID
        timescale = BinaryPrimitives.ReadUInt32BigEndian(body[p..]);
        p += 4;
        long firstOffset;
        if (version == 0)
        {
            p += 4;
            firstOffset = BinaryPrimitives.ReadUInt32BigEndian(body[p..]);
            p += 4;
        }
        else
        {
            p += 8;
            firstOffset = (long)BinaryPrimitives.ReadUInt64BigEndian(body[p..]);
            p += 8;
        }
        p += 2; // reserved
        var count = BinaryPrimitives.ReadUInt16BigEndian(body[p..]);
        p += 2;
        var refs = new List<FragmentRef>(count);
        var offset = end + firstOffset;
        for (var i = 0; i < count; i++)
        {
            var word = BinaryPrimitives.ReadUInt32BigEndian(body[p..]);
            if ((word & 0x80000000) != 0) return null; // a reference to another index: not used by YouTube
            var size = word & 0x7FFFFFFF;
            var duration = BinaryPrimitives.ReadUInt32BigEndian(body[(p + 4)..]);
            refs.Add(new FragmentRef(offset, size, duration));
            offset += size;
            p += 12;
        }
        return refs;
    }

    // MARK: Fragments

    /// <summary>Reads one fragment's <c>moof</c> (its first bytes are enough). <paramref name="moofOffset"/> is where it
    /// starts in the file; <paramref name="defaults"/> are the trex defaults from the head's moov. Null when
    /// <paramref name="data"/> doesn't hold the whole moof (<paramref name="needed"/> then says how many bytes would).</summary>
    public static Fragment? ParseMoof(ReadOnlySpan<byte> data, long moofOffset, TrackDefaults defaults, out int needed)
    {
        needed = 0;
        if (data.Length < 8) { needed = 8; return null; }
        var (size, type, header) = BoxAt(data, 0);
        if (type != "moof") throw new FormatException($"expected moof at {moofOffset}, found {type}");
        if (size > data.Length) { needed = (int)size; return null; }
        var moof = data[..(int)size];
        foreach (var (trafStart, trafSize) in Children(moof, header))
        {
            if (Type(moof, trafStart) != "traf") continue;
            var traf = moof.Slice((int)trafStart, (int)trafSize);
            long baseOffset = moofOffset;
            uint defaultSize = defaults.SampleSize, defaultDuration = defaults.SampleDuration;
            foreach (var (s, n) in Children(traf, 8))
            {
                var box = traf.Slice((int)s, (int)n);
                var flags = BinaryPrimitives.ReadUInt32BigEndian(box[8..]) & 0xFFFFFF;
                switch (Type(traf, s))
                {
                    case "tfhd":
                    {
                        var p = 16; // header, version/flags, track_ID
                        if ((flags & 0x01) != 0) { baseOffset = (long)BinaryPrimitives.ReadUInt64BigEndian(box[p..]); p += 8; }
                        if ((flags & 0x02) != 0) p += 4;
                        if ((flags & 0x08) != 0) { defaultDuration = BinaryPrimitives.ReadUInt32BigEndian(box[p..]); p += 4; }
                        if ((flags & 0x10) != 0) { defaultSize = BinaryPrimitives.ReadUInt32BigEndian(box[p..]); p += 4; }
                        break;
                    }
                    case "trun":
                    {
                        var count = (int)BinaryPrimitives.ReadUInt32BigEndian(box[12..]);
                        var p = 16;
                        long dataOffset = 0;
                        if ((flags & 0x01) != 0) { dataOffset = BinaryPrimitives.ReadInt32BigEndian(box[p..]); p += 4; }
                        if ((flags & 0x04) != 0) p += 4;
                        var sizes = new uint[count];
                        var durations = new uint[count];
                        for (var i = 0; i < count; i++)
                        {
                            durations[i] = defaultDuration;
                            sizes[i] = defaultSize;
                            if ((flags & 0x100) != 0) { durations[i] = BinaryPrimitives.ReadUInt32BigEndian(box[p..]); p += 4; }
                            if ((flags & 0x200) != 0) { sizes[i] = BinaryPrimitives.ReadUInt32BigEndian(box[p..]); p += 4; }
                            if ((flags & 0x400) != 0) p += 4;
                            if ((flags & 0x800) != 0) p += 4;
                        }
                        return new Fragment(baseOffset + dataOffset, sizes, durations);
                    }
                }
            }
        }
        throw new FormatException($"no trun in the moof at {moofOffset}");
    }

    /// <summary>The trex defaults of the head's only track.</summary>
    public readonly record struct TrackDefaults(uint SampleDuration, uint SampleSize);

    public static TrackDefaults Defaults(Head head)
    {
        var moov = head.Moov.AsSpan();
        foreach (var (s, n) in Children(moov, 8))
        {
            if (Type(moov, s) != "mvex") continue;
            foreach (var (t, m) in Children(moov.Slice((int)s, (int)n), 8))
            {
                var mvex = moov.Slice((int)s, (int)n);
                if (Type(mvex, t) != "trex") continue;
                var trex = mvex.Slice((int)t, (int)m);
                return new TrackDefaults(BinaryPrimitives.ReadUInt32BigEndian(trex[20..]), BinaryPrimitives.ReadUInt32BigEndian(trex[24..]));
            }
        }
        return new TrackDefaults(1024, 0);
    }

    // MARK: Building the flat file

    /// <summary>The flat MP4 for <paramref name="head"/> and its fragments, in order.</summary>
    public static Layout Build(Head head, IReadOnlyList<Fragment> fragments)
    {
        var sizes = fragments.SelectMany(f => f.Sizes).ToArray();
        var durations = fragments.SelectMany(f => f.Durations).ToArray();
        var mediaDuration = durations.Sum(d => (long)d);

        // stts: runs of equal durations.
        var stts = new List<(uint Count, uint Delta)>();
        foreach (var d in durations)
        {
            if (stts.Count > 0 && stts[^1].Delta == d) stts[^1] = (stts[^1].Count + 1, d);
            else stts.Add((1, d));
        }
        // One chunk per fragment; stsc: runs of chunks with the same sample count.
        var stsc = new List<(uint FirstChunk, uint Samples)>();
        for (var i = 0; i < fragments.Count; i++)
        {
            var n = (uint)fragments[i].Sizes.Length;
            if (stsc.Count == 0 || stsc[^1].Samples != n) stsc.Add(((uint)i + 1, n));
        }

        var moov = head.Moov;
        uint mediaTimescale = MediaTimescale(moov) ?? head.Timescale;
        uint movieTimescale = MovieTimescale(moov) ?? mediaTimescale;
        var movieDuration = (ulong)(mediaDuration * (double)movieTimescale / mediaTimescale);

        var ftyp = Box("ftyp", w =>
        {
            w.Ascii("M4A ");
            w.U32(0);
            foreach (var brand in new[] { "M4A ", "mp42", "isom" }) w.Ascii(brand);
        });

        // stco needs the flat offsets of the data, which depend on the header's size: build the moov once with zero
        // offsets to learn its size, then again with the real ones (same size).
        byte[] BuildMoov(uint[] chunkOffsets) => RewriteMoov(moov, movieDuration, (ulong)mediaDuration, stts, stsc, sizes, chunkOffsets);
        var placeholder = BuildMoov(new uint[fragments.Count]);
        var headerLength = ftyp.Length + placeholder.Length + 8L;
        var offsets = new uint[fragments.Count];
        var segments = new List<Segment>(fragments.Count);
        var flat = headerLength;
        for (var i = 0; i < fragments.Count; i++)
        {
            offsets[i] = checked((uint)flat);
            segments.Add(new Segment(flat, fragments[i].DataOffset, fragments[i].DataLength));
            flat += fragments[i].DataLength;
        }
        var newMoov = BuildMoov(offsets);
        if (newMoov.Length != placeholder.Length) throw new InvalidOperationException("moov size changed");
        var mdatSize = checked((uint)(flat - headerLength + 8));
        var header = new byte[headerLength];
        ftyp.CopyTo(header, 0);
        newMoov.CopyTo(header, ftyp.Length);
        BinaryPrimitives.WriteUInt32BigEndian(header.AsSpan((int)headerLength - 8), mdatSize);
        "mdat"u8.CopyTo(header.AsSpan((int)headerLength - 4));
        return new Layout(header, segments, flat, mediaDuration / (double)mediaTimescale);
    }

    static uint? MovieTimescale(byte[] moov)
    {
        foreach (var (s, _) in Children(moov, 8))
            if (Type(moov, s) == "mvhd") return BinaryPrimitives.ReadUInt32BigEndian(moov.AsSpan((int)s + (moov[(int)s + 8] == 1 ? 28 : 20)));
        return null;
    }

    static uint? MediaTimescale(byte[] moov)
    {
        var span = moov.AsSpan();
        foreach (var (t, tn) in Children(span, 8))
        {
            if (Type(span, t) != "trak") continue;
            var trak = span.Slice((int)t, (int)tn);
            foreach (var (m, mn) in Children(trak, 8))
            {
                if (Type(trak, m) != "mdia") continue;
                var mdia = trak.Slice((int)m, (int)mn);
                foreach (var (h, _) in Children(mdia, 8))
                    if (Type(mdia, h) == "mdhd") return BinaryPrimitives.ReadUInt32BigEndian(mdia[((int)h + (mdia[(int)h + 8] == 1 ? 28 : 20))..]);
            }
        }
        return null;
    }

    /// <summary>The moov with durations set, mvex dropped and the sample table filled in.</summary>
    static byte[] RewriteMoov(byte[] moov, ulong movieDuration, ulong mediaDuration, List<(uint Count, uint Delta)> stts,
        List<(uint FirstChunk, uint Samples)> stsc, uint[] sizes, uint[] chunkOffsets)
    {
        byte[] Rewrite(ReadOnlySpan<byte> box, string path)
        {
            var (size, type, header) = BoxAt(box, 0);
            var full = path.Length == 0 ? type : path + "/" + type;
            switch (full)
            {
                case "moov" or "moov/trak" or "moov/trak/mdia" or "moov/trak/mdia/minf":
                {
                    var children = new List<byte[]>();
                    foreach (var (s, n) in Children(box, header))
                    {
                        var childType = Type(box, s);
                        if (full == "moov" && childType == "mvex") continue;
                        children.Add(Rewrite(box.Slice((int)s, (int)n), full));
                    }
                    return Container(type, box[8..header].ToArray(), children);
                }
                case "moov/trak/mdia/minf/stbl":
                {
                    var children = new List<byte[]>();
                    foreach (var (s, n) in Children(box, header))
                    {
                        var childType = Type(box, s);
                        if (childType is "stts" or "stsc" or "stsz" or "stco" or "co64" or "ctts" or "stss") continue;
                        children.Add(box.Slice((int)s, (int)n).ToArray());
                    }
                    children.Add(Box("stts", w => { w.U32(0); w.U32((uint)stts.Count); foreach (var (c, d) in stts) { w.U32(c); w.U32(d); } }));
                    children.Add(Box("stsc", w => { w.U32(0); w.U32((uint)stsc.Count); foreach (var (f, n) in stsc) { w.U32(f); w.U32(n); w.U32(1); } }));
                    children.Add(Box("stsz", w => { w.U32(0); w.U32(0); w.U32((uint)sizes.Length); foreach (var s in sizes) w.U32(s); }));
                    children.Add(Box("stco", w => { w.U32(0); w.U32((uint)chunkOffsets.Length); foreach (var o in chunkOffsets) w.U32(o); }));
                    return Container(type, [], children);
                }
                case "moov/mvhd":
                    return WithDuration(box, box[8] == 1 ? 32 : 24, box[8] == 1, movieDuration);
                case "moov/trak/tkhd":
                    return WithDuration(box, box[8] == 1 ? 36 : 28, box[8] == 1, movieDuration);
                case "moov/trak/mdia/mdhd":
                    return WithDuration(box, box[8] == 1 ? 32 : 24, box[8] == 1, mediaDuration);
                default:
                    return box[..(int)size].ToArray();
            }
        }
        return Rewrite(moov, "");
    }

    static byte[] WithDuration(ReadOnlySpan<byte> box, int at, bool wide, ulong duration)
    {
        var copy = box.ToArray();
        if (wide) BinaryPrimitives.WriteUInt64BigEndian(copy.AsSpan(at), duration);
        else BinaryPrimitives.WriteUInt32BigEndian(copy.AsSpan(at), (uint)Math.Min(duration, uint.MaxValue));
        return copy;
    }

    // MARK: Boxes

    static (long Size, string Type, int Header) BoxAt(ReadOnlySpan<byte> data, long pos)
    {
        var p = (int)pos;
        long size = BinaryPrimitives.ReadUInt32BigEndian(data[p..]);
        var type = Type(data, pos);
        var header = 8;
        if (size == 1)
        {
            size = (long)BinaryPrimitives.ReadUInt64BigEndian(data[(p + 8)..]);
            header = 16;
        }
        else if (size == 0)
        {
            size = data.Length - pos;
        }
        return (size, type, header);
    }

    static string Type(ReadOnlySpan<byte> data, long pos) => System.Text.Encoding.ASCII.GetString(data.Slice((int)pos + 4, 4));

    static List<(long Start, long Size)> Children(ReadOnlySpan<byte> box, int header)
    {
        var list = new List<(long, long)>();
        long pos = header;
        while (pos + 8 <= box.Length)
        {
            var (size, _, _) = BoxAt(box, pos);
            if (size < 8 || pos + size > box.Length) break;
            list.Add((pos, size));
            pos += size;
        }
        return list;
    }

    static byte[] Container(string type, byte[] prefix, List<byte[]> children)
    {
        var length = 8 + prefix.Length + children.Sum(c => c.Length);
        var output = new byte[length];
        BinaryPrimitives.WriteUInt32BigEndian(output, (uint)length);
        System.Text.Encoding.ASCII.GetBytes(type, output.AsSpan(4));
        prefix.CopyTo(output, 8);
        var p = 8 + prefix.Length;
        foreach (var c in children)
        {
            c.CopyTo(output, p);
            p += c.Length;
        }
        return output;
    }

    sealed class Writer
    {
        public readonly List<byte> Bytes = [];
        public void U32(uint v) { Span<byte> b = stackalloc byte[4]; BinaryPrimitives.WriteUInt32BigEndian(b, v); Bytes.AddRange(b.ToArray()); }
        public void Ascii(string s) => Bytes.AddRange(System.Text.Encoding.ASCII.GetBytes(s));
    }

    static byte[] Box(string type, Action<Writer> body)
    {
        var w = new Writer();
        body(w);
        return Container(type, [.. w.Bytes], []);
    }
}
