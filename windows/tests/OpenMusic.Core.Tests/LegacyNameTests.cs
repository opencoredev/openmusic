using OpenMusic.Core.Mock;

namespace OpenMusic.Core.Tests;

/// <summary>Names from before the rename that older scripts and saved files still use.</summary>
public class LegacyNameTests
{
    [Fact]
    public void AnOpenMusicVariableFallsBackToItsMedleySpelling()
    {
        var env = new Dictionary<string, string> { ["MEDLEY_NO_ART"] = "1", ["OPENMUSIC_DEMO_ART"] = "new", ["MEDLEY_DEMO_ART"] = "old" };
        string? Lookup(string name) => env.TryGetValue(name, out var value) ? value : null;
        Assert.Equal("1", LaunchEnvironment.Get("OPENMUSIC_NO_ART", Lookup));
        Assert.Equal("new", LaunchEnvironment.Get("OPENMUSIC_DEMO_ART", Lookup));
        Assert.Null(LaunchEnvironment.Get("OPENMUSIC_YTM_DEBUG", Lookup));
        Assert.Null(LaunchEnvironment.Get("NO_ART", Lookup));
    }

    [Fact]
    public void MockArtworkSavedUnderTheOldSchemeStillDraws()
    {
        var old = new Uri("medley-mock://art/yt-al0");
        Assert.True(MockArtwork.IsMock(old));
        Assert.True(MockArtwork.IsMock(MockArtwork.Url("art", "yt-al0")));
        Assert.False(MockArtwork.IsMock(new Uri("https://example.com/art.jpg")));
        Assert.Equal(MockArtwork.Render(MockArtwork.Url("art", "yt-al0"), 32), MockArtwork.Render(old, 32));
    }
}
