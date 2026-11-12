using System.ComponentModel;
using CommunityToolkit.Mvvm.ComponentModel;
using Medley.Core;

namespace Medley.App.ViewModels;

/// <summary>
/// The Play button of an album or playlist page, kept in step with the player: "Pause" while one of the list's songs
/// plays, "Play" otherwise. Pressing it pauses or resumes that song rather than starting the list over. The page attaches
/// it while it's on screen (the player outlives every page).
/// </summary>
public sealed partial class ListPlayState(Func<IReadOnlyCollection<string>> trackIds, Action playFromStart) : ObservableObject
{
    private const string PlayGlyphText = "";
    private const string PauseGlyphText = "";

    [ObservableProperty] public partial string Label { get; set; } = "Play";
    [ObservableProperty] public partial string Glyph { get; set; } = PlayGlyphText;

    private PlayerController Player => App.Services.Player;

    /// <summary>One of the list's songs is the current one (playing or paused).</summary>
    public bool IsCurrent => Player.Current is { } t && trackIds().Contains(t.Id);

    public void Attach()
    {
        Player.PropertyChanged += Changed;
        Update();
    }

    public void Detach() => Player.PropertyChanged -= Changed;

    public void Press()
    {
        if (IsCurrent) Player.TogglePlayPause();
        else playFromStart();
    }

    /// <summary>The list's songs changed (loaded, more pages).</summary>
    public void Update()
    {
        var playing = IsCurrent && Player.IsPlaying;
        Label = playing ? "Pause" : "Play";
        Glyph = playing ? PauseGlyphText : PlayGlyphText;
    }

    private void Changed(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(PlayerController.Current) or nameof(PlayerController.IsPlaying)) Update();
    }
}
