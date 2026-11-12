using OpenMusic.App.Services;
using OpenMusic.App.ViewModels;
using OpenMusic.Core;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace OpenMusic.App.Pages;

/// <summary>
/// Radio: the stations played lately (kept on this PC), and stations to start from the songs, artists and mixes on Home
/// and New. A song station is YouTube's "radio" for that song; an artist's is its own radio playlist.
/// </summary>
public sealed partial class RadioPage : Page
{
    private int _version = -1;

    public RadioPage()
    {
        InitializeComponent();
        Controls.ListHelpers.AttachContextMenu(Stations, item => item is CardItem card ? MediaMenus.For(card.Item) : null);
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        var services = App.Services;
        var recent = services.Settings.Values.Stations.Select(Station).ToList();
        Recent.ItemsSource = recent;
        RecentHeader.Visibility = Recent.Visibility = recent.Count > 0 ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;
        if (_version == services.SessionVersion && Stations.ItemsSource is not null) return;
        _version = services.SessionVersion;
        if (services.Mock is { } mock)
        {
            Stations.ItemsSource = mock.Catalog.Artists.Select(a => new CardItem(MediaItem.Of(a with { Name = a.Name }), "Artist station")).ToList();
            return;
        }
        Loading.IsActive = true;
        try
        {
            var home = await services.Cache.GetAsync("shelves:home", async () => (await services.Provider.HomeAsync()).Select(s => new ShelfModel(s)).ToList());
            var items = home.SelectMany(s => s.Shelf.Items).ToList();
            var cards = new List<CardItem>();
            var seen = new HashSet<string>();
            foreach (var item in items.OfType<MediaItem.ArtistItem>().Take(8))
                if (seen.Add(item.Id)) cards.Add(new CardItem(item, "Artist station"));
            foreach (var item in items.OfType<MediaItem.TrackItem>().Take(16))
                if (seen.Add(item.Id)) cards.Add(new CardItem(item, $"Song station · {item.Track.ArtistLine}"));
            foreach (var item in items.OfType<MediaItem.PlaylistItem>().Where(p => p.Playlist.Extra.GetValueOrDefault("moreToken") is null).Take(8))
                if (seen.Add(item.Id)) cards.Add(new CardItem(item, "Mix station"));
            Stations.ItemsSource = cards;
        }
        catch (Exception ex)
        {
            ShellPage.Current.ShowPageError("Couldn't load stations", PageViewModel.Friendly(ex), "Try Again", () => { _version = -1; ShellPage.Current.Reload(); return Task.CompletedTask; });
        }
        finally
        {
            Loading.IsActive = false;
        }
    }

    private static CardItem Station(AppSettings.RecentStation s)
    {
        Uri? art = s.Artwork is { } a && Uri.TryCreate(a, UriKind.Absolute, out var u) ? u : null;
        var playlist = new Playlist { ProviderID = s.Seed, Provider = App.Services.Provider.Id, Title = s.Name, Artwork = Artwork.FromUrl(art) };
        var card = new CardItem(MediaItem.Of(playlist), s.Kind switch { "track" => $"Song station{(s.Detail is { } d ? " · " + d : "")}", "artist" => "Artist station", _ => "Mix station" })
        {
            Station = s,
        };
        return card;
    }

    private async void Stations_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not CardItem card) return;
        if (card.Station is { } recent)
        {
            if (recent.Kind == "track")
            {
                var track = new Track { ProviderID = recent.Seed, Provider = App.Services.Provider.Id, Title = recent.Name };
                await MediaMenus.StartTrackRadioAsync(track);
            }
            else await MediaMenus.StartSeedRadioAsync(recent.Seed, recent.Name, card.Artwork, recent.Kind);
            return;
        }
        switch (card.Item)
        {
            case MediaItem.TrackItem t: await MediaMenus.StartTrackRadioAsync(t.Track); break;
            case MediaItem.ArtistItem a when App.Services.Mock is not null:
                await App.Services.Player.PlayRadioAsync($"radio-{a.Artist.ProviderID}", a.Artist.Provider, a.Artist.Name);
                break;
            case MediaItem.ArtistItem a: await MediaMenus.StartArtistRadioAsync(a.Artist); break;
            case MediaItem.PlaylistItem p: await MediaMenus.StartSeedRadioAsync(p.Playlist.ProviderID, p.Playlist.Title, card.Artwork); break;
        }
    }
}
