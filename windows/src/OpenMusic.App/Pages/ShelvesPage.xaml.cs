using OpenMusic.App.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace OpenMusic.App.Pages;

public sealed partial class ShelvesPage : Page
{
    public const string Home = "home";
    public const string New = "new";

    private string? _kind;
    private int _version = -1;
    private IReadOnlyList<ShelfModel>? _drawn;

    public ShelvesViewModel ViewModel { get; } = new();

    public ShelvesPage()
    {
        InitializeComponent();
        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(ShelvesViewModel.Shelves)) Draw();
        };
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        var kind = e.Parameter as string ?? Home;
        if (kind == _kind && _version == App.Services.SessionVersion) return; // cached page, same screen and account: already drawn
        if (kind != _kind) Scroller.ChangeView(null, 0, null, disableAnimation: true);
        _kind = kind;
        _version = App.Services.SessionVersion;
        Heading.Text = kind == New ? "New" : "Home";
        ShelfHost.ItemsSource = null;
        _drawn = null;
        // A spinner only when there's nothing to show yet (first launch, or a new account).
        var load = ViewModel.LoadAsync(kind);
        if (!load.IsCompleted && ViewModel.Shelves.Count == 0 || _drawn is null) Loading.IsActive = true;
        await load;
        Loading.IsActive = false;
    }

    private static bool _loggedFirstDraw;

    private void Draw()
    {
        var shelves = ViewModel.Shelves;
        if (ReferenceEquals(shelves, _drawn)) return;
        if (!_loggedFirstDraw && shelves.Count > 0)
        {
            _loggedFirstDraw = true;
            Services.Log.Info($"timing: {Heading.Text} drawn at {App.SinceLaunch:F0} ms ({shelves.Count} shelves{(ViewModel.IsRefreshing ? ", from the disk cache" : "")})");
        }
        _drawn = shelves;
        Loading.IsActive = false;
        ShelfHost.ItemsSource = shelves;
    }
}
