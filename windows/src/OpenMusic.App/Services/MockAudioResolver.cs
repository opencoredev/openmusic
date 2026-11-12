using System.Buffers.Binary;
using OpenMusic.Core;
using OpenMusic.Core.Mock;

namespace OpenMusic.App.Services;

/// <summary>
/// The stream resolver for mock mode: every song plays as a soft, generated arpeggio as long as the song, written once
/// as a small WAV (22.05 kHz mono) under %LOCALAPPDATA%\OpenMusic\mock-audio, so real audio goes through MediaPlayer, the
/// scrubber and synced lyrics behave as with a real stream, and nothing comes from the network. With
/// <c>--mock-audio-url</c> every song plays that URL instead.
/// </summary>
public sealed class MockAudioResolver(Uri? overrideUrl = null) : IStreamResolver
{
    private const int SampleRate = 22050;
    private static readonly string Folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), ProductInfo.FolderName, "mock-audio");

    public async Task<PlayableStream> ResolveStreamAsync(Track track, bool forceRefresh, CancellationToken ct)
    {
        if (overrideUrl is not null) return new PlayableStream(overrideUrl);
        var seconds = Math.Clamp(track.Duration ?? 200, 5, 900);
        var path = Path.Combine(Folder, $"{SeededRandom.Fnv1a(track.Id):x16}-{(int)seconds}.wav");
        if (!File.Exists(path)) await Task.Run(() => Write(path, track.Id, seconds), ct).ConfigureAwait(false);
        return new PlayableStream(new Uri(path)) { Duration = seconds, MimeType = "audio/wav" };
    }

    private static void Write(string path, string seed, double seconds)
    {
        Directory.CreateDirectory(Folder);
        var samples = (int)(seconds * SampleRate);
        var data = new byte[44 + samples * 2];
        var span = data.AsSpan();
        // RIFF/WAVE header, PCM 16-bit mono.
        "RIFF"u8.CopyTo(span);
        BinaryPrimitives.WriteInt32LittleEndian(span[4..], 36 + samples * 2);
        "WAVEfmt "u8.CopyTo(span[8..]);
        BinaryPrimitives.WriteInt32LittleEndian(span[16..], 16);
        BinaryPrimitives.WriteInt16LittleEndian(span[20..], 1);
        BinaryPrimitives.WriteInt16LittleEndian(span[22..], 1);
        BinaryPrimitives.WriteInt32LittleEndian(span[24..], SampleRate);
        BinaryPrimitives.WriteInt32LittleEndian(span[28..], SampleRate * 2);
        BinaryPrimitives.WriteInt16LittleEndian(span[32..], 2);
        BinaryPrimitives.WriteInt16LittleEndian(span[34..], 16);
        "data"u8.CopyTo(span[36..]);
        BinaryPrimitives.WriteInt32LittleEndian(span[40..], samples * 2);

        // A I–V–vi–IV progression in a key picked from the song, one chord per 2 s bar, arpeggiated in eighth notes
        // with a plucked envelope, over a soft root note.
        var rng = new SeededRandom(SeededRandom.Fnv1a("tone-" + seed));
        var root = 196.0 * Math.Pow(2, rng.Int(0, 7) / 12.0);
        int[][] chords = [[0, 4, 7, 12], [7, 11, 14, 19], [9, 12, 16, 21], [5, 9, 12, 17]];
        const double bar = 2.0, step = 0.25;
        for (var i = 0; i < samples; i++)
        {
            var t = (double)i / SampleRate;
            var chord = chords[(int)(t / bar) % 4];
            var noteIndex = (int)(t / step);
            var note = chord[noteIndex % 4];
            var nt = t - noteIndex * step;
            var f = root * Math.Pow(2, note / 12.0);
            var pluck = Math.Exp(-nt * 7) * (Math.Sin(2 * Math.PI * f * t) + 0.25 * Math.Sin(4 * Math.PI * f * t));
            var bt = t % bar;
            var bass = 0.5 * Math.Exp(-bt * 1.6) * Math.Sin(2 * Math.PI * root / 2 * Math.Pow(2, chord[0] / 12.0) * t);
            var fade = Math.Min(1, Math.Min(t / 0.8, (seconds - t) / 1.5));
            var v = 0.16 * fade * (pluck + bass);
            BinaryPrimitives.WriteInt16LittleEndian(span[(44 + i * 2)..], (short)Math.Clamp(v * short.MaxValue, short.MinValue, short.MaxValue));
        }
        var tmp = path + ".tmp";
        File.WriteAllBytes(tmp, data);
        File.Move(tmp, path, overwrite: true);
    }
}
