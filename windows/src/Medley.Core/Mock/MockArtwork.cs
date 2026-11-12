namespace Medley.Core.Mock;

/// <summary>
/// Procedural cover art for the mock provider, so the UI and snapshots work offline. URLs look like
/// <c>medley-mock://art/&lt;seed&gt;</c>, <c>medley-mock://portrait/&lt;seed&gt;</c>, <c>medley-mock://demo/&lt;key&gt;</c>
/// (a downloaded cover, see <see cref="DemoDirectory"/>), <c>medley-mock://mosaic/&lt;k1+k2+k3+k4&gt;</c>,
/// <c>medley-mock://liked/&lt;provider&gt;</c> and <c>medley-mock://avatar/&lt;initials&gt;</c>. The same seed always draws the
/// same image, with the Swift mock's colors and shapes (the same generator), drawn by a small software rasterizer.
/// </summary>
public static class MockArtwork
{
    public const string Scheme = "medley-mock";

    /// <summary>Where the demo dataset's downloaded cover art lives (<c>&lt;key&gt;.jpg</c>, from scripts/demo-art.sh). Set once
    /// at launch. The core can't decode JPEG; the app reads these files itself and falls back to <see cref="Render"/>.</summary>
    public static string? DemoDirectory { get; set; }

    public static Uri Url(string kind, string seed) => new($"{Scheme}://{kind}/{seed}");

    public static Artwork Artwork(string kind, string seed) => new([new ArtworkImage(Url(kind, seed), 1200, 1200)]);

    public static bool IsMock(Uri url) => url.Scheme == Scheme;

    /// <summary>The kind ("art", "portrait", "demo", …) and seed of a mock URL.</summary>
    public static (string Kind, string Seed) Parse(Uri url) => (url.Host.Length > 0 ? url.Host : "art", Uri.UnescapeDataString(url.Segments[^1]));

    /// <summary>The demo cover file for <paramref name="key"/>, when <see cref="DemoDirectory"/> has it.</summary>
    public static string? DemoFile(string key)
    {
        if (DemoDirectory is not { } dir) return null;
        var path = Path.Combine(dir, key + ".jpg");
        return File.Exists(path) ? path : null;
    }

    /// <summary>Draws a mock URL at <paramref name="pixels"/>² as premultiplied BGRA rows, top row first. "demo" and
    /// "mosaic" tiles without a downloaded file get a procedural cover from their key. Safe on any thread.</summary>
    public static byte[] Render(Uri url, int pixels)
    {
        var (kind, seed) = Parse(url);
        var size = Math.Clamp(pixels, 16, 2048);
        var canvas = new Canvas(size);
        var rng = new SeededRandom(SeededRandom.Fnv1a(seed));
        switch (kind)
        {
            case "portrait": DrawPortrait(canvas, ref rng); break;
            case "liked": DrawLiked(canvas); break;
            case "avatar": DrawAvatar(canvas); break;
            default: DrawCover(canvas, ref rng); break;
        }
        return canvas.ToBgra();
    }

    /// <summary>The procedural cover for a seed (a demo key without its file, one tile of a mosaic).</summary>
    public static byte[] RenderCover(string seed, int pixels)
    {
        var canvas = new Canvas(Math.Clamp(pixels, 16, 2048));
        var rng = new SeededRandom(SeededRandom.Fnv1a(seed));
        DrawCover(canvas, ref rng);
        return canvas.ToBgra();
    }

    /// <summary>A rough average color of the art for a seed, for placeholders and backdrops.</summary>
    public static (byte R, byte G, byte B) Tint(Uri url)
    {
        var (_, seed) = Parse(url);
        var rng = new SeededRandom(SeededRandom.Fnv1a(seed));
        var hue = rng.Unit();
        var c = Hsb(hue, 0.55 + rng.Unit() * 0.3, 0.55 + rng.Unit() * 0.35);
        return ((byte)(c.R * 255), (byte)(c.G * 255), (byte)(c.B * 255));
    }

    // MARK: Drawing (CG coordinates: origin bottom-left, as in the Swift code)

    private static void DrawCover(Canvas ctx, ref SeededRandom rng)
    {
        double s = ctx.Size;
        var hue = rng.Unit();
        var shift = 0.06 + rng.Unit() * 0.22;
        var a = Hsb(hue, 0.55 + rng.Unit() * 0.3, 0.55 + rng.Unit() * 0.35);
        var b = Hsb(hue + shift, 0.5 + rng.Unit() * 0.35, 0.25 + rng.Unit() * 0.35);
        var c = Hsb(hue - shift * 1.4, 0.35 + rng.Unit() * 0.4, 0.85 + rng.Unit() * 0.15);
        ctx.Linear(a, b, 0, s, s, 0);

        switch ((int)(rng.Unit() * 4))
        {
            case 0:
            {
                // A low sun with a horizon band.
                var r = s * (0.22 + rng.Unit() * 0.16);
                var cx = s * (0.3 + rng.Unit() * 0.4);
                var cy = s * (0.4 + rng.Unit() * 0.25);
                ctx.Ellipse(cx, cy, r, r, c.WithAlpha(0.92));
                ctx.Rect(0, 0, s, cy - r * 0.15, b.WithAlpha(0.85));
                for (var i = 0; i < 5; i++)
                {
                    var y = cy - r * 0.15 - (i + 1) * s * 0.045;
                    ctx.Rect(0, y, s, s * 0.012, c.WithAlpha(0.18 - i * 0.03));
                }
                break;
            }
            case 1:
            {
                // Concentric rings.
                var cx = s * rng.Unit();
                var cy = s * rng.Unit();
                for (var i = 9; i >= 1; i--)
                {
                    var r = s * 0.13 * i;
                    ctx.Ellipse(cx, cy, r, r, (i % 2 == 0 ? c : a).WithAlpha(0.16 + 0.05 * (9 - i)));
                }
                break;
            }
            case 2:
            {
                // Diagonal bands, rotated ±45° around the center.
                var angle = Math.PI / 4 * (rng.Unit() > 0.5 ? 1 : -1);
                var band = s * (0.08 + rng.Unit() * 0.08);
                var x = -s;
                var i = 0;
                while (x < s)
                {
                    var color = (i % 3 == 0 ? c : a).WithAlpha(i % 3 == 0 ? 0.75 : 0.22);
                    ctx.RotatedRect(s / 2, s / 2, angle, x, -s, band * (i % 3 == 0 ? 0.6 : 1), s * 2, color);
                    x += band * 1.6;
                    i++;
                }
                break;
            }
            default:
            {
                // Soft blobs.
                for (var n = 0; n < 4; n++)
                {
                    var r = s * (0.18 + rng.Unit() * 0.3);
                    var px = s * rng.Unit();
                    var py = s * rng.Unit();
                    ctx.Radial(c.WithAlpha(0.8), c.WithAlpha(0), px, py, r, extendEnd: true);
                }
                break;
            }
        }
        // Subtle vignette for depth.
        ctx.Radial(new Rgba(0, 0, 0, 0), new Rgba(0, 0, 0, 0.28), s / 2, s / 2, s * 0.75, extendEnd: true);
    }

    private static void DrawPortrait(Canvas ctx, ref SeededRandom rng)
    {
        double s = ctx.Size;
        var hue = rng.Unit();
        var bg1 = Hsb(hue, 0.35 + rng.Unit() * 0.3, 0.7 + rng.Unit() * 0.25);
        var bg2 = Hsb(hue + 0.1, 0.5, 0.3 + rng.Unit() * 0.2);
        ctx.Radial(bg1, bg2, s * 0.5, s * 0.62, s * 0.8, extendEnd: true);
        var figure = Hsb(hue + 0.5, 0.25, 0.12 + rng.Unit() * 0.12).WithAlpha(0.88);
        var headR = s * (0.15 + rng.Unit() * 0.04);
        var hx = s * (0.47 + rng.Unit() * 0.06);
        var hy = s * 0.56;
        ctx.Ellipse(hx, hy, headR, headR * 1.1, figure);
        // Shoulders: CGRect(x: hx - 0.36s, y: -0.25s, w: 0.72s, h: 0.62s).
        ctx.Ellipse(hx, -s * 0.25 + s * 0.31, s * 0.36, s * 0.31, figure);
        // Rim light.
        ctx.Radial(bg1.WithAlpha(0.35), bg1.WithAlpha(0), s * 0.8, s * 0.8, s * 0.5, extendEnd: true);
    }

    /// <summary>"Liked" playlist art: a deep violet-to-blue gradient with a white heart.</summary>
    private static void DrawLiked(Canvas ctx)
    {
        double s = ctx.Size;
        ctx.Linear(new Rgba(0.27, 0.13, 0.85, 1), new Rgba(0.55, 0.78, 0.95, 1), 0, s, s, 0);
        var w = s * 0.36;
        var cx = s / 2;
        var cy = s * 0.5;
        // The classic implicit heart, (x² + y² − 1)³ − x²y³ ≤ 0, scaled to the Swift heart's width.
        ctx.Shape((x, y) =>
        {
            var u = (x - cx) / (w * 0.62);
            var v = (y - cy) / (w * 0.62);
            var q = u * u + v * v - 1;
            return q * q * q - u * u * v * v * v;
        }, new Rgba(1, 1, 1, 1));
    }

    /// <summary>An account picture without a photo: a warm gradient. The app draws the initials over it.</summary>
    private static void DrawAvatar(Canvas ctx)
    {
        double s = ctx.Size;
        ctx.Linear(new Rgba(0.98, 0.55, 0.33, 1), new Rgba(0.86, 0.25, 0.52, 1), 0, s, s, 0);
    }

    internal static Rgba Hsb(double h, double s, double v)
    {
        h = (h % 1 + 1) % 1 * 6;
        var i = (int)h;
        var f = h - i;
        double p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f));
        return (i % 6) switch
        {
            0 => new Rgba(v, t, p, 1),
            1 => new Rgba(q, v, p, 1),
            2 => new Rgba(p, v, t, 1),
            3 => new Rgba(p, q, v, 1),
            4 => new Rgba(t, p, v, 1),
            _ => new Rgba(v, p, q, 1),
        };
    }

    internal readonly record struct Rgba(double R, double G, double B, double A)
    {
        public Rgba WithAlpha(double a) => this with { A = Math.Clamp(a, 0, 1) };

        public static Rgba Lerp(Rgba x, Rgba y, double t) =>
            new(x.R + (y.R - x.R) * t, x.G + (y.G - x.G) * t, x.B + (y.B - x.B) * t, x.A + (y.A - x.A) * t);
    }

    /// <summary>A tiny software canvas: straight-alpha source-over compositing into premultiplied RGB, with edge
    /// antialiasing by one pixel of coverage. Coordinates are CG's (y up), pixel centers at +0.5.</summary>
    private sealed class Canvas(int size)
    {
        public int Size { get; } = size;
        private readonly double[] _px = new double[size * size * 4];

        private void Blend(int ix, int iy, Rgba c, double coverage)
        {
            var a = c.A * Math.Clamp(coverage, 0, 1);
            if (a <= 0) return;
            var o = ((Size - 1 - iy) * Size + ix) * 4;
            _px[o] = c.R * a + _px[o] * (1 - a);
            _px[o + 1] = c.G * a + _px[o + 1] * (1 - a);
            _px[o + 2] = c.B * a + _px[o + 2] * (1 - a);
            _px[o + 3] = a + _px[o + 3] * (1 - a);
        }

        private void Each(Func<double, double, (Rgba Color, double Coverage)> f)
        {
            for (var iy = 0; iy < Size; iy++)
            {
                var y = iy + 0.5;
                for (var ix = 0; ix < Size; ix++)
                {
                    var (c, cov) = f(ix + 0.5, y);
                    Blend(ix, iy, c, cov);
                }
            }
        }

        /// <summary>A linear gradient from (x0, y0) to (x1, y1), extended past both ends.</summary>
        public void Linear(Rgba from, Rgba to, double x0, double y0, double x1, double y1)
        {
            double dx = x1 - x0, dy = y1 - y0, len2 = dx * dx + dy * dy;
            Each((x, y) => (Rgba.Lerp(from, to, Math.Clamp(((x - x0) * dx + (y - y0) * dy) / len2, 0, 1)), 1));
        }

        /// <summary>A radial gradient from the center out to <paramref name="radius"/>; past it, the end color when
        /// <paramref name="extendEnd"/> (CG's drawsAfterEndLocation), else nothing.</summary>
        public void Radial(Rgba from, Rgba to, double cx, double cy, double radius, bool extendEnd)
        {
            Each((x, y) =>
            {
                var t = Math.Sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy)) / radius;
                if (t > 1 && !extendEnd) return (to, 0);
                return (Rgba.Lerp(from, to, Math.Min(t, 1)), 1);
            });
        }

        public void Ellipse(double cx, double cy, double rx, double ry, Rgba color)
        {
            Each((x, y) =>
            {
                var u = (x - cx) / rx;
                var v = (y - cy) / ry;
                var d = Math.Sqrt(u * u + v * v);
                // Distance to the edge in pixels, roughly: (1 - d) × the smaller radius.
                return (color, 0.5 + (1 - d) * Math.Min(rx, ry));
            });
        }

        public void Rect(double x, double y, double w, double h, Rgba color)
        {
            Each((px, py) =>
            {
                var cx = Math.Clamp(Math.Min(px - x, x + w - px) + 0.5, 0, 1);
                var cy = Math.Clamp(Math.Min(py - y, y + h - py) + 0.5, 0, 1);
                return (color, cx * cy);
            });
        }

        /// <summary>A rect in a frame translated to (ox, oy) and rotated by <paramref name="angle"/>.</summary>
        public void RotatedRect(double ox, double oy, double angle, double x, double y, double w, double h, Rgba color)
        {
            double cos = Math.Cos(-angle), sin = Math.Sin(-angle);
            Each((px, py) =>
            {
                double lx = (px - ox) * cos - (py - oy) * sin, ly = (px - ox) * sin + (py - oy) * cos;
                var cx = Math.Clamp(Math.Min(lx - x, x + w - lx) + 0.5, 0, 1);
                var cy = Math.Clamp(Math.Min(ly - y, y + h - ly) + 0.5, 0, 1);
                return (color, cx * cy);
            });
        }

        /// <summary>Fills where <paramref name="f"/> is ≤ 0, antialiased by 2×2 supersampling.</summary>
        public void Shape(Func<double, double, double> f, Rgba color)
        {
            Each((x, y) =>
            {
                var inside = 0;
                for (var sy = -0.25; sy <= 0.25; sy += 0.5)
                    for (var sx = -0.25; sx <= 0.25; sx += 0.5)
                        if (f(x + sx, y + sy) <= 0) inside++;
                return (color, inside / 4.0);
            });
        }

        public byte[] ToBgra()
        {
            var output = new byte[Size * Size * 4];
            for (var i = 0; i < Size * Size; i++)
            {
                var o = i * 4;
                output[o] = ToByte(_px[o + 2]);
                output[o + 1] = ToByte(_px[o + 1]);
                output[o + 2] = ToByte(_px[o]);
                output[o + 3] = ToByte(_px[o + 3]);
            }
            return output;
        }

        private static byte ToByte(double v) => (byte)Math.Clamp(Math.Round(v * 255), 0, 255);
    }
}
