using Medley.Core;
using Medley.Core.Support;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;

namespace Medley.App.Services;

/// <summary>
/// Right-click menus for songs, albums, artists and playlists, the same everywhere they appear: Play, Play Next, Add to
/// Queue, Go to Album / Artist, Add to Playlist (with New Playlist), Like, Remove from Playlist, Start Radio, Copy Link.
/// Account actions show only while signed in, and writes go out bound to the account the menu was opened for: a sign-in
/// that changes meanwhile makes the write fail rather than land in another account.
/// </summary>
public static class MediaMenus
{
    private static AppServices S => App.Services;
    private static IMusicProvider Provider => S.Provider;
    private static ShellPage Shell => ShellPage.Current;

    /// <summary>The menu for a card or a search suggestion.</summary>
    public static MenuFlyout For(MediaItem item) => item switch
    {
        MediaItem.TrackItem t => ForTrack(t.Track),
        MediaItem.AlbumItem a => ForAlbum(a.Album),
        MediaItem.ArtistItem a => ForArtist(a.Artist),
        MediaItem.PlaylistItem p => ForPlaylist(p.Playlist),
        _ => new MenuFlyout(),
    };

    /// <summary>A song's menu. <paramref name="list"/> plays the whole list from the song; <paramref name="inPlaylist"/>
    /// adds Remove from Playlist for an editable playlist.</summary>
    public static MenuFlyout ForTrack(Track track, Func<(IReadOnlyList<Track> Tracks, int Index, PlaybackContext? Context)>? list = null,
        Playlist? inPlaylist = null, Action? removed = null)
    {
        var menu = new MenuFlyout();
        menu.Opening += (_, _) =>
        {
            menu.Items.Clear();
            var signedIn = Provider.IsSignedIn;
            var caps = Provider.Capabilities;
            var account = WriteAccount();
            menu.Items.Add(Item("Play", "\uE768", "MenuPlay", () =>
            {
                if (list?.Invoke() is { } l) S.Player.Play(l.Tracks, startAt: l.Index, context: l.Context);
                else S.Player.Play(track);
            }));
            menu.Items.Add(Item("Play Next", "\uE8FD", "MenuPlayNext", () => { S.Player.PlayNext([track]); Shell.ShowNotice($"“{track.Title}” plays next", InfoBarSeverity.Informational); }));
            menu.Items.Add(Item("Add to Queue", "\uE710", "MenuAddToQueue", () => { S.Player.AddToQueue([track]); Shell.ShowNotice($"Added “{track.Title}” to the queue", InfoBarSeverity.Informational); }));
            if (caps.HasFlag(ProviderCapabilities.Radio))
                menu.Items.Add(Item("Start Radio", "\uEC05", "MenuStartRadio", () => _ = StartTrackRadioAsync(track)));
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(Item("Go to Album", "\uE93C", "MenuGoToAlbum", () => _ = GoToAlbumAsync(track)));
            menu.Items.Add(Item("Go to Artist", "\uE77B", "MenuGoToArtist", () => _ = GoToArtistAsync(track)));
            if (signedIn && (caps.HasFlag(ProviderCapabilities.PlaylistEditing) || caps.HasFlag(ProviderCapabilities.Like)))
            {
                menu.Items.Add(new MenuFlyoutSeparator());
                if (caps.HasFlag(ProviderCapabilities.PlaylistEditing)) menu.Items.Add(AddToPlaylistMenu([track], account));
                if (caps.HasFlag(ProviderCapabilities.Like)) menu.Items.Add(LikeItem(track, account));
                if (inPlaylist is { IsEditable: true } playlist && caps.HasFlag(ProviderCapabilities.PlaylistEditing))
                    menu.Items.Add(Item("Remove from Playlist", "\uE74D", "MenuRemoveFromPlaylist", () => _ = RemoveAsync(track, playlist, account, removed)));
            }
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(CopyLinkItem(MediaItem.Of(track)));
        };
        return menu;
    }

    public static MenuFlyout ForAlbum(Album album)
    {
        var menu = new MenuFlyout();
        menu.Opening += (_, _) =>
        {
            menu.Items.Clear();
            menu.Items.Add(Item("Play", "\uE768", "MenuPlay", () => _ = WithTracks(album, (t, c) => S.Player.Play(t, shuffled: false, context: c))));
            menu.Items.Add(Item("Shuffle", "\uE8B1", "MenuShuffle", () => _ = WithTracks(album, (t, c) => S.Player.Play(t, shuffled: true, context: c))));
            menu.Items.Add(Item("Play Next", "\uE8FD", "MenuPlayNext", () => _ = WithTracks(album, (t, c) => { S.Player.PlayNext(t, c); Shell.ShowNotice($"“{album.Title}” plays next", InfoBarSeverity.Informational); })));
            menu.Items.Add(Item("Add to Queue", "\uE710", "MenuAddToQueue", () => _ = WithTracks(album, (t, c) => { S.Player.AddToQueue(t, c); Shell.ShowNotice($"Added “{album.Title}” to the queue", InfoBarSeverity.Informational); })));
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(Item("Go to Album", "\uE93C", "MenuGoToAlbum", () => Shell.Navigate("album", album.ProviderID)));
            if (album.Artists.FirstOrDefault(a => a.Id is not null) is { } artist)
                menu.Items.Add(Item("Go to Artist", "\uE77B", "MenuGoToArtist", () => Shell.Navigate("artist", artist.Id)));
            if (Provider.IsSignedIn && Provider.Capabilities.HasFlag(ProviderCapabilities.PlaylistEditing))
            {
                menu.Items.Add(new MenuFlyoutSeparator());
                var account = WriteAccount();
                var sub = AddToPlaylistMenu([], account);
                sub.Tag = album;
                menu.Items.Add(sub);
            }
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(CopyLinkItem(MediaItem.Of(album)));
        };
        return menu;
    }

    public static MenuFlyout ForArtist(Artist artist)
    {
        var menu = new MenuFlyout();
        menu.Opening += (_, _) =>
        {
            menu.Items.Clear();
            menu.Items.Add(Item("Go to Artist", "\uE77B", "MenuGoToArtist", () => Shell.Navigate("artist", artist.ProviderID)));
            if (Provider.Capabilities.HasFlag(ProviderCapabilities.Radio))
                menu.Items.Add(Item("Start Radio", "\uEC05", "MenuStartRadio", () => _ = StartArtistRadioAsync(artist)));
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(CopyLinkItem(MediaItem.Of(artist)));
        };
        return menu;
    }

    public static MenuFlyout ForPlaylist(Playlist playlist)
    {
        var menu = new MenuFlyout();
        menu.Opening += (_, _) =>
        {
            menu.Items.Clear();
            menu.Items.Add(Item("Play", "\uE768", "MenuPlay", () => _ = WithTracks(playlist, (t, c) => S.Player.Play(t, shuffled: false, context: c))));
            menu.Items.Add(Item("Shuffle", "\uE8B1", "MenuShuffle", () => _ = WithTracks(playlist, (t, c) => S.Player.Play(t, shuffled: true, context: c))));
            menu.Items.Add(Item("Play Next", "\uE8FD", "MenuPlayNext", () => _ = WithTracks(playlist, (t, c) => { S.Player.PlayNext(t, c); Shell.ShowNotice($"“{playlist.Title}” plays next", InfoBarSeverity.Informational); })));
            menu.Items.Add(Item("Add to Queue", "\uE710", "MenuAddToQueue", () => _ = WithTracks(playlist, (t, c) => { S.Player.AddToQueue(t, c); Shell.ShowNotice($"Added “{playlist.Title}” to the queue", InfoBarSeverity.Informational); })));
            if (Provider.Capabilities.HasFlag(ProviderCapabilities.Radio))
                menu.Items.Add(Item("Start Radio", "\uEC05", "MenuStartRadio", () => _ = StartSeedRadioAsync(playlist.ProviderID, playlist.Title, playlist.Artwork?.Url(300))));
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(CopyLinkItem(MediaItem.Of(playlist)));
        };
        return menu;
    }

    // MARK: Pieces

    private static MenuFlyoutItem Item(string text, string glyph, string id, Action run)
    {
        var item = new MenuFlyoutItem { Text = text, Icon = new FontIcon { Glyph = glyph } };
        AutomationProperties.SetAutomationId(item, id);
        item.Click += (_, _) => run();
        return item;
    }

    private static PlaylistWriteAccount WriteAccount() => new(Provider.AuthStatus.Account?.Id, Provider.Session);

    private static MenuFlyoutItem CopyLinkItem(MediaItem item) => Item("Copy Link", "\uE71B", "MenuCopyLink", () =>
    {
        if (WebLinks.For(item) is not { } url) return;
        var data = new DataPackage();
        data.SetText(url.AbsoluteUri);
        data.SetWebLink(url);
        Clipboard.SetContent(data);
        Shell.ShowNotice("Link copied", InfoBarSeverity.Informational);
    });

    /// <summary>Whether the current service can like songs for the account signed in now.</summary>
    public static bool CanLike => Provider.IsSignedIn && Provider.Capabilities.HasFlag(ProviderCapabilities.Like);

    /// <summary>Likes or unlikes <paramref name="track"/> for the account signed in when this was asked (the player bar's
    /// heart); returns whether the change was made.</summary>
    public static Task<bool> SetLikedAsync(Track track, bool liked) => SetLikedAsync(track, liked, WriteAccount());

    private static async Task<bool> SetLikedAsync(Track track, bool liked, PlaylistWriteAccount account)
    {
        try
        {
            // Bound to the account the action was offered for: a sign-in that changed since sends nothing.
            await Provider.SetLikedAsync(track, liked, account);
            S.Cache.RemoveWhere(k => k.StartsWith("library:all:LikedSongs", StringComparison.Ordinal));
            Shell.ShowNotice(liked ? $"Added “{track.Title}” to Liked Songs" : $"Removed “{track.Title}” from Liked Songs", InfoBarSeverity.Success);
            return true;
        }
        catch (PlaylistEditException e) when (e.IsAccountChanged)
        {
            Shell.ShowNotice("Nothing changed: the YouTube Music account changed since the menu opened.", InfoBarSeverity.Warning);
        }
        catch (Exception e)
        {
            Shell.ShowNotice($"Couldn't change Liked Songs. {e.Message}", InfoBarSeverity.Error);
        }
        return false;
    }

    /// <summary>Like or remove from Liked Songs; the text follows the song's state once the service says it.</summary>
    private static MenuFlyoutItem LikeItem(Track track, PlaylistWriteAccount account)
    {
        var item = Item("Like", "\uEB51", "MenuLike", () => { });
        var liked = false;
        _ = Fill();
        async Task Fill()
        {
            try
            {
                liked = await Provider.IsLikedAsync(track);
                item.Text = liked ? "Remove from Liked Songs" : "Like";
                item.Icon = new FontIcon { Glyph = liked ? "\uEB52" : "\uEB51" };
            }
            catch (Exception)
            {
                // Unknown: keep "Like".
            }
        }
        item.Click += async (_, _) => await SetLikedAsync(track, !liked, account);
        return item;
    }

    /// <summary>Add to Playlist ›: New Playlist…, then the account's own playlists.</summary>
    private static MenuFlyoutSubItem AddToPlaylistMenu(IReadOnlyList<Track> tracks, PlaylistWriteAccount account)
    {
        var sub = new MenuFlyoutSubItem { Text = "Add to Playlist", Icon = new FontIcon { Glyph = "\uE90B" } };
        AutomationProperties.SetAutomationId(sub, "MenuAddToPlaylist");
        async Task<IReadOnlyList<Track>> Resolve() => tracks.Count > 0 ? tracks
            : sub.Tag is Album album ? (await Provider.AlbumAsync(album.ProviderID)).Tracks : [];
        sub.Items.Add(Item("New Playlist…", "\uE710", "MenuNewPlaylist", () => _ = NewPlaylistAsync(Resolve, account)));
        var playlists = Shell.KnownPlaylists.Where(p => p.IsEditable).ToList();
        if (playlists.Count > 0) sub.Items.Add(new MenuFlyoutSeparator());
        foreach (var playlist in playlists.Take(30))
        {
            var p = playlist;
            sub.Items.Add(Item(p.Title, "\uEC4F", "MenuPlaylist-" + p.ProviderID, () => _ = AddAsync(Resolve, p, account)));
        }
        return sub;
    }

    private static async Task AddAsync(Func<Task<IReadOnlyList<Track>>> tracks, Playlist playlist, PlaylistWriteAccount account)
    {
        try
        {
            var list = await tracks();
            if (list.Count == 0) return;
            await Provider.AddAsync(list, playlist.ProviderID, account);
            S.Cache.Remove($"playlist:{playlist.ProviderID}");
            Shell.ShowNotice(list.Count == 1 ? $"Added “{list[0].Title}” to {playlist.Title}" : $"Added {list.Count} songs to {playlist.Title}", InfoBarSeverity.Success);
        }
        catch (PlaylistEditException e)
        {
            Shell.ShowNotice($"Nothing was added: {e.Message}", InfoBarSeverity.Warning);
        }
        catch (Exception e)
        {
            Shell.ShowNotice($"Couldn't add to {playlist.Title}. {e.Message}", InfoBarSeverity.Error);
        }
    }

    /// <summary>New Playlist: a name and an optional description, then the songs go in.</summary>
    public static async Task NewPlaylistAsync(Func<Task<IReadOnlyList<Track>>>? tracks, PlaylistWriteAccount? account = null)
    {
        account ??= WriteAccount();
        var name = new TextBox { Header = "Name", PlaceholderText = "My playlist", MinWidth = 360 };
        AutomationProperties.SetAutomationId(name, "NewPlaylistName");
        var description = new TextBox { Header = "Description (optional)", AcceptsReturn = false, Margin = new Thickness(0, 12, 0, 0) };
        var panel = new StackPanel();
        panel.Children.Add(name);
        panel.Children.Add(description);
        var dialog = new ContentDialog
        {
            Title = "New Playlist",
            Content = panel,
            PrimaryButtonText = "Create",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            IsPrimaryButtonEnabled = false,
        };
        name.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = name.Text.Trim().Length > 0;
        if (await Dialogs.ShowAsync(dialog) != ContentDialogResult.Primary) return;
        try
        {
            var playlist = await Provider.CreatePlaylistAsync(name.Text.Trim(), description.Text.Trim() is { Length: > 0 } d ? d : null, account);
            var list = tracks is null ? [] : await tracks();
            if (list.Count > 0) await Provider.AddAsync(list, playlist.ProviderID, account);
            Shell.RefreshPlaylists();
            Shell.ShowNotice(list.Count > 0 ? $"Created {playlist.Title} with {list.Count} song{(list.Count == 1 ? "" : "s")}" : $"Created {playlist.Title}", InfoBarSeverity.Success);
        }
        catch (Exception e)
        {
            Shell.ShowNotice($"Couldn't create the playlist. {e.Message}", InfoBarSeverity.Error);
        }
    }

    private static async Task RemoveAsync(Track track, Playlist playlist, PlaylistWriteAccount account, Action? removed)
    {
        try
        {
            await Provider.RemoveAsync([track], playlist.ProviderID, account);
            S.Cache.Remove($"playlist:{playlist.ProviderID}");
            Shell.ShowNotice($"Removed “{track.Title}” from {playlist.Title}", InfoBarSeverity.Success);
            removed?.Invoke();
        }
        catch (Exception e)
        {
            Shell.ShowNotice($"Couldn't remove it. {e.Message}", InfoBarSeverity.Error);
        }
    }

    private static async Task GoToAlbumAsync(Track track)
    {
        var t = track.Album?.Id is null ? await Linked(track) : track;
        if (t.Album?.Id is { } id) Shell.Navigate("album", id);
        else Shell.ShowNotice("This song has no album page.", InfoBarSeverity.Informational);
    }

    private static async Task GoToArtistAsync(Track track)
    {
        var t = track.Artists.Any(a => a.Id is not null) ? track : await Linked(track);
        if (t.Artists.FirstOrDefault(a => a.Id is not null)?.Id is { } id) Shell.Navigate("artist", id);
        else Shell.ShowNotice("This song has no artist page.", InfoBarSeverity.Informational);
    }

    private static async Task<Track> Linked(Track track)
    {
        try { return await Provider.LinkedTrackAsync(track); }
        catch (Exception) { return track; }
    }

    private static async Task WithTracks(Album album, Action<IReadOnlyList<Track>, PlaybackContext> run)
    {
        try
        {
            var detail = await S.Cache.GetAsync($"album:{album.ProviderID}", () => Provider.AlbumAsync(album.ProviderID));
            run(detail.Tracks, PlaybackContext.ForAlbum(detail.Album));
        }
        catch (Exception e)
        {
            Shell.ShowNotice($"Couldn't load {album.Title}. {e.Message}", InfoBarSeverity.Error);
        }
    }

    private static async Task WithTracks(Playlist playlist, Action<IReadOnlyList<Track>, PlaybackContext> run)
    {
        try
        {
            var detail = await Provider.PlaylistAsync(playlist.ProviderID);
            var pager = new PlaylistPager(detail);
            while (pager.HasMore && pager.PagesLoaded < 4) await pager.LoadNextAsync((token, ct) => Provider.PlaylistTracksAsync(token, ct));
            run(pager.Tracks, PlaybackContext.ForPlaylist(detail.Playlist));
        }
        catch (Exception e)
        {
            Shell.ShowNotice($"Couldn't load {playlist.Title}. {e.Message}", InfoBarSeverity.Error);
        }
    }

    // MARK: Radio

    public static async Task StartTrackRadioAsync(Track track)
    {
        try
        {
            await S.Player.PlayRadioAsync(track);
            S.Settings.AddStation(new AppSettings.RecentStation { Seed = track.ProviderID, Kind = "track", Name = track.Title, Detail = track.ArtistLine, Artwork = track.Artwork?.Url(300)?.AbsoluteUri });
        }
        catch (Exception e)
        {
            Shell.ShowNotice($"Couldn't start the radio. {e.Message}", InfoBarSeverity.Error);
        }
    }

    public static async Task StartArtistRadioAsync(Artist artist)
    {
        try
        {
            var detail = await S.Cache.GetAsync($"artist:{artist.ProviderID}", () => Provider.ArtistAsync(artist.ProviderID));
            if (detail.RadioSeed is not { } seed)
            {
                Shell.ShowNotice($"{artist.Name} has no radio.", InfoBarSeverity.Informational);
                return;
            }
            await StartSeedRadioAsync(seed, $"{detail.Artist.Name}", (detail.Artist.Artwork ?? artist.Artwork)?.Url(300), "artist");
        }
        catch (Exception e)
        {
            Shell.ShowNotice($"Couldn't start the radio. {e.Message}", InfoBarSeverity.Error);
        }
    }

    public static async Task StartSeedRadioAsync(string seed, string title, Uri? artwork, string kind = "playlist")
    {
        try
        {
            await S.Player.PlayRadioAsync(seed, Provider.Id, title);
            S.Settings.AddStation(new AppSettings.RecentStation { Seed = seed, Kind = kind, Name = title, Artwork = artwork?.AbsoluteUri });
        }
        catch (Exception e)
        {
            Shell.ShowNotice($"Couldn't start the radio. {e.Message}", InfoBarSeverity.Error);
        }
    }
}
