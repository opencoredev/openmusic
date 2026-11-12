using System.Buffers.Binary;
using OpenMusic.Providers.YouTube.Playback;
using Xunit;

namespace OpenMusic.Providers.YouTube.Tests;

/// <summary>The flat-MP4 view of a fragmented MP4 (YouTube's itag 140 layout: ftyp moov sidx (moof mdat)…).
/// Fixtures/fmp4_sine.m4a is 6 s of AAC made by ffmpeg with a global sidx and moof-relative offsets.</summary>
public class FragmentedMp4Tests
{
    static byte[] Fixture() => File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "fmp4_sine.m4a"));

    static (FragmentedMp4.Head Head, List<FragmentedMp4.Fragment> Fragments) Parse(byte[] file)
    {
        var head = FragmentedMp4.ParseHead(file, out _) ?? throw new Xunit.Sdk.XunitException("no head");
        var defaults = FragmentedMp4.Defaults(head);
        var fragments = head.Fragments.Select(r => FragmentedMp4.ParseMoof(file.AsSpan((int)r.Offset), r.Offset, defaults, out _)!).ToList();
        return (head, fragments);
    }

    /// <summary>Assembles the whole flat file the way the player's stream reads it.</summary>
    static byte[] Flatten(byte[] file, FragmentedMp4.Layout layout)
    {
        var output = new byte[layout.Length];
        layout.Header.CopyTo(output, 0);
        foreach (var s in layout.Segments) Array.Copy(file, s.SourceOffset, output, s.FlatOffset, s.Length);
        return output;
    }

    [Fact]
    public void ReadsTheIndexAndEveryFragment()
    {
        var file = Fixture();
        var (head, fragments) = Parse(file);
        Assert.True(head.Fragments.Count >= 5);
        // ffmpeg ends with an mfra box after the last fragment; YouTube's files end with the last mdat.
        Assert.InRange(head.Fragments[^1].Offset + head.Fragments[^1].Size, file.Length - 400, file.Length);
        // Every fragment's data ends where its mdat ends: sizes add up.
        foreach (var (r, f) in head.Fragments.Zip(fragments))
            Assert.Equal(r.Offset + r.Size, f.DataOffset + f.DataLength);
        var samples = fragments.Sum(f => f.Sizes.Length);
        Assert.InRange(samples, 6 * 44100 / 1024 - 2, 6 * 44100 / 1024 + 4);
    }

    [Fact]
    public void HeadNeedsMoreBytesUntilTheSidxIsIn()
    {
        var file = Fixture();
        Assert.Null(FragmentedMp4.ParseHead(file.AsSpan(0, 400), out var needed));
        Assert.True(needed > 400);
        Assert.NotNull(FragmentedMp4.ParseHead(file.AsSpan(0, (int)needed + 200), out _));
    }

    [Fact]
    public void FlatFileHasOneMdatWithEverySampleInOrder()
    {
        var file = Fixture();
        var (head, fragments) = Parse(file);
        var layout = FragmentedMp4.Build(head, fragments);
        var flat = Flatten(file, layout);
        // ftyp, moov, mdat, nothing else.
        var boxes = TopLevel(flat);
        Assert.Equal(["ftyp", "moov", "mdat"], boxes.Select(b => b.Type));
        Assert.Equal(flat.Length, boxes.Sum(b => b.Size));
        Assert.Equal(layout.Header.Length, boxes[0].Size + boxes[1].Size + 8);
        // The mdat payload is the fragments' sample data back to back.
        var expected = fragments.SelectMany(f => file.AsSpan((int)f.DataOffset, (int)f.DataLength).ToArray()).ToArray();
        Assert.Equal(expected, flat.AsSpan(layout.Header.Length).ToArray());
        Assert.InRange(layout.Seconds, 5.9, 6.1);
        // No mvex left, and a sample table that counts every sample.
        var moov = flat.AsSpan((int)boxes[1].Offset, (int)boxes[1].Size).ToArray();
        Assert.DoesNotContain("mvex", Types(moov));
        var stsz = Find(moov, "stsz");
        Assert.Equal((uint)fragments.Sum(f => f.Sizes.Length), BinaryPrimitives.ReadUInt32BigEndian(moov.AsSpan(stsz + 16)));
        var stco = Find(moov, "stco");
        Assert.Equal((uint)fragments.Count, BinaryPrimitives.ReadUInt32BigEndian(moov.AsSpan(stco + 12)));
        Assert.Equal((uint)layout.Header.Length, BinaryPrimitives.ReadUInt32BigEndian(moov.AsSpan(stco + 16)));
    }

    [Fact]
    public void SegmentIndexFindsEveryByte()
    {
        var file = Fixture();
        var (head, fragments) = Parse(file);
        var layout = FragmentedMp4.Build(head, fragments);
        Assert.Equal(-1, layout.SegmentIndex(0));
        Assert.Equal(0, layout.SegmentIndex(layout.Header.Length));
        var last = layout.Segments[^1];
        Assert.Equal(layout.Segments.Count - 1, layout.SegmentIndex(last.FlatOffset + last.Length - 1));
        Assert.Equal(-1, layout.SegmentIndex(layout.Length));
    }

    /// <summary>A real file: OPENMUSIC_FMP4_FILE=in.m4a OPENMUSIC_FMP4_OUT=flat.m4a writes the flat view for ffprobe.</summary>
    [Fact]
    public void WritesTheFlatViewOfAFileWhenAsked()
    {
        if (OpenMusic.Core.LaunchEnvironment.Get("OPENMUSIC_FMP4_FILE") is not { } input || OpenMusic.Core.LaunchEnvironment.Get("OPENMUSIC_FMP4_OUT") is not { } output) return;
        var file = File.ReadAllBytes(input);
        var (head, fragments) = Parse(file);
        File.WriteAllBytes(output, Flatten(file, FragmentedMp4.Build(head, fragments)));
    }

    static List<(string Type, long Offset, long Size)> TopLevel(byte[] data)
    {
        var list = new List<(string, long, long)>();
        long p = 0;
        while (p + 8 <= data.Length)
        {
            var size = BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan((int)p));
            list.Add((System.Text.Encoding.ASCII.GetString(data, (int)p + 4, 4), p, size));
            p += size;
        }
        return list;
    }

    static IEnumerable<string> Types(byte[] moov)
    {
        for (var i = 4; i + 4 <= moov.Length; i++)
            if (moov.AsSpan(i, 4).ToArray().All(b => b is >= (byte)'a' and <= (byte)'z')) yield return System.Text.Encoding.ASCII.GetString(moov, i, 4);
    }

    static int Find(byte[] moov, string type)
    {
        var needle = System.Text.Encoding.ASCII.GetBytes(type);
        return moov.AsSpan().IndexOf(needle) - 4;
    }
}
