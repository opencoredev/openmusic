using System.ComponentModel;
using OpenMusic.App.Services;
using OpenMusic.Core;
using OpenMusic.Sync;
using OpenMusic.Sync.Account;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Shapes;
using VirtualKey = Windows.System.VirtualKey;

namespace OpenMusic.App.Controls;

/// <summary>
/// The first run (onboarding/flow.md): Welcome, Your music, Sync (optional), Approve this PC (only when another device
/// holds the account's key), then Home. It shows once: finishing or skipping any step sets
/// <see cref="AppSettings.Data.WelcomeDone"/>, which no update resets. UI thread only.
/// <para>Sign-ins go through <see cref="AccountService"/> as everywhere else; whatever is in flight when the listener moves
/// on is ignored here (each step's work checks <see cref="_generation"/> after every await) but a sign-in that finishes
/// still counts: the account connects as if it had finished on screen.</para>
/// </summary>
public sealed partial class OnboardingView : UserControl
{
    public enum Step { Welcome, Music, Sync, Approve }

    private const string Here = "this PC";
    private static string Name => ProductInfo.Name;

    /// <summary>The listener finished or skipped the flow: the shell shows Home.</summary>
    public event Action? Finished;

    public Step Current { get; private set; }
    public bool CanGoBack => Current is Step.Music or Step.Sync && !_busy;

    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _resendTimer;
    private int _resendLeft;
    private int _generation;
    private bool _busy;
    private bool _youTubeChosen;
    private bool _approveNeeded;
    private bool _finished;
    private bool _serverSwitched;
    private bool _approvedShown;
    private string? _approveShape;
    /// <summary>The server was switched but this process couldn't restart: sync still points at the old server.</summary>
    private bool _restartRequired;
    private ClerkEmailChallenge? _challenge;
    private Uri? _checkedServer;
    private KeyComparison? _shownComparison;
    private SyncHub? _sync;

    public OnboardingView()
    {
        InitializeComponent();
        YouTubeArt.Content = BrandMarks.YouTubeMusic(64);
        SpotifyArt.Content = BrandMarks.Spotify(64);
        YouTubeMark.Content = BrandMarks.YouTubeMusic(40);
        SpotifyMark.Content = BrandMarks.Spotify(40);
        YouTubeGoogleMark.Content = BrandMarks.Google(14);
        AppleMark.Content = BrandMarks.Apple(17);
        GoogleMark.Content = BrandMarks.Google(16);
        WelcomeTitle.Text = Name;
        StepEyebrow.Text = $"Optional {Name} account";
        _resendTimer = DispatcherQueue.CreateTimer();
        _resendTimer.Interval = TimeSpan.FromSeconds(1);
        _resendTimer.Tick += (_, _) => TickResend();
        Card.Shadow = new ThemeShadow();
        BrowserSignIn.Completing += () =>
        {
            BrowserCancelButton.IsEnabled = BrowserReopenButton.IsEnabled = false;
            BrowserBar.Message = "Finishing sign-in…";
        };
        SizeChanged += (_, e) => Layout(e.NewSize);
        AddHandler(KeyDownEvent, new KeyEventHandler(Root_KeyDown), true);
    }

    // MARK: Showing

    /// <summary>Shows the flow at <paramref name="step"/> (Welcome on a first launch; Sync after a restart to switch servers).</summary>
    public void Start(Step step)
    {
        _finished = false;
        _sync = App.Services.Sync;
        App.Services.Provider.PropertyChanged -= Provider_PropertyChanged;
        App.Services.Provider.PropertyChanged += Provider_PropertyChanged;
        if (_sync is { } sync)
        {
            sync.Account.PropertyChanged -= Account_PropertyChanged;
            sync.Account.PropertyChanged += Account_PropertyChanged;
            sync.Service.PropertyChanged -= Service_PropertyChanged;
            sync.Service.PropertyChanged += Service_PropertyChanged;
        }
        Show(step);
    }

    private void Show(Step step)
    {
        _generation++;
        Current = step;
        WelcomeStep.Visibility = Visible(step == Step.Welcome);
        MusicStep.Visibility = Visible(step == Step.Music);
        SyncStep.Visibility = Visible(step == Step.Sync);
        ApproveStep.Visibility = Visible(step == Step.Approve);
        WelcomeArt.Visibility = Visible(step == Step.Welcome);
        MusicArt.Visibility = Visible(step == Step.Music);
        SyncArt.Visibility = Visible(step == Step.Sync);
        ApproveArt.Visibility = Visible(step == Step.Approve);
        StepHost.VerticalAlignment = step == Step.Welcome ? VerticalAlignment.Center : VerticalAlignment.Top;
        StepHeader.Visibility = Visible(step != Step.Welcome);
        StepEyebrow.Visibility = Visible(step == Step.Sync);
        StepNote.Visibility = Visible(step == Step.Sync);
        (StepTitle.Text, StepBody.Text) = step switch
        {
            Step.Music => ("Your music", "Choose where your music comes from. You can change this later in Settings."),
            Step.Sync => ("Pick up where you left off.", "Sign in to see what's playing on your other devices and move it here with one tap."),
            Step.Approve => ("Approve this PC", StepBody.Text),
            _ => ("", ""),
        };
        LayoutPadding();
        StepScroller.ChangeView(null, 0, null, true);
        switch (step)
        {
            case Step.Welcome:
                SetFooter("Get Started", accent: true, enabled: true);
                break;
            case Step.Music:
                UpdateYouTube();
                break;
            case Step.Sync:
                SetFooter("Not Now", accent: false, enabled: true);
                UpdateSync();
                break;
            case Step.Approve:
                SetFooter("Do This Later", accent: false, enabled: true);
                UpdateApprove();
                break;
        }
        UpdatePips();
        ShellPage.Current.OnboardingStepChanged();
        Animate();
        // Focus the step's first choice, quietly (programmatic focus draws no focus box).
        DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () =>
        {
            Control? first = step switch
            {
                Step.Welcome => PrimaryButton,
                Step.Music => PrimaryButton,
                Step.Sync => AppleButton.Visibility == Visibility.Visible ? AppleButton : GoogleButton.Visibility == Visibility.Visible ? GoogleButton : EmailBox,
                _ => CodesMatchButton.Visibility == Visibility.Visible && ApproveCompare.Visibility == Visibility.Visible ? CodesMatchButton : PrimaryButton,
            };
            // Pointer focus: Enter and Space work at once, and no focus box shows until the keyboard moves it.
            first?.Focus(FocusState.Pointer);
        });
    }

    private void Animate()
    {
        var transform = new TranslateTransform { X = 28 };
        StepHost.RenderTransform = transform;
        StepHost.Opacity = 0;
        var ease = new ExponentialEase { EasingMode = EasingMode.EaseOut, Exponent = 6 };
        var board = new Storyboard();
        var slide = new DoubleAnimation { To = 0, Duration = TimeSpan.FromMilliseconds(360), EasingFunction = ease };
        Storyboard.SetTarget(slide, transform);
        Storyboard.SetTargetProperty(slide, "X");
        var fade = new DoubleAnimation { To = 1, Duration = TimeSpan.FromMilliseconds(200) };
        Storyboard.SetTarget(fade, StepHost);
        Storyboard.SetTargetProperty(fade, "Opacity");
        board.Children.Add(slide);
        board.Children.Add(fade);
        board.Begin();
    }

    private static Visibility Visible(bool on) => on ? Visibility.Visible : Visibility.Collapsed;

    private void SetFooter(string text, bool accent, bool enabled)
    {
        PrimaryButton.Content = text;
        PrimaryButton.Style = (Style)Resources[accent ? "FooterAccentButtonStyle" : "FooterButtonStyle"];
        PrimaryButton.IsEnabled = enabled;
        SecondaryButton.Visibility = Visibility.Collapsed;
    }

    /// <summary>Where you are: Your music, Sync, and Approve when this PC needs it. Welcome shows none.</summary>
    private void UpdatePips()
    {
        Pips.Children.Clear();
        if (Current == Step.Welcome)
        {
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(Pips, "");
            return;
        }
        var count = _approveNeeded ? 3 : 2;
        var index = Current switch { Step.Music => 0, Step.Sync => 1, _ => 2 };
        for (var i = 0; i < count; i++)
        {
            Pips.Children.Add(new Rectangle { Style = (Style)Resources[i == index ? "PipOnStyle" : "PipOffStyle"] });
        }
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(Pips, $"Step {index + 1} of {count}");
    }

    private void Layout(Windows.Foundation.Size size)
    {
        var narrow = size.Width < 860;
        ArtColumn.Width = narrow ? new GridLength(0) : new GridLength(5, GridUnitType.Star);
        ArtPane.Visibility = Visible(!narrow);
        WelcomeSmallIcon.Visibility = Visible(narrow);
        var shortWindow = size.Height < 600;
        Root.Padding = narrow || shortWindow ? new Thickness(16, 0, 16, 16) : new Thickness(32, 4, 32, 32);
        LayoutPadding();
        Footer.Padding = narrow ? new Thickness(28, 12, 28, 20) : new Thickness(44, 12, 44, 28);
    }

    /// <summary>The sign-in column is as wide as the step allows, up to 480: a form, not a banner.</summary>
    private void SyncStep_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        var width = Math.Min(480, e.NewSize.Width);
        SignInChoices.Width = PrivacyRow.Width = ServerSection.Width = width;
    }

    /// <summary>Welcome has no header (its content is centered); other steps' forms start just under their heading.</summary>
    private void LayoutPadding()
    {
        var narrow = ActualWidth > 0 && ActualWidth < 860;
        var side = narrow ? 28 : 44;
        StepHeader.Padding = new Thickness(side, narrow ? 32 : 48, side, 0);
        StepHost.Padding = new Thickness(side, Current == Step.Welcome ? (narrow ? 32 : 48) : 12, side, narrow ? 16 : 20);
        HeaderDivider.Margin = new Thickness(side, 0, side, 0);
    }

    private void StepScroller_ViewChanged(object? sender, ScrollViewerViewChangedEventArgs e) =>
        HeaderDivider.Visibility = Visible(Current != Step.Welcome && StepScroller.VerticalOffset > 1);

    // MARK: Footer, Back, Esc

    private void Primary_Click(object sender, RoutedEventArgs e)
    {
        switch (Current)
        {
            case Step.Welcome: Show(Step.Music); break;
            case Step.Music when !App.Services.Provider.AuthStatus.IsSignedIn && !_youTubeChosen: UseYouTubeSignedOut(); break;
            case Step.Music: Show(Step.Sync); break;
            case Step.Sync: Finish("not now"); break;
            case Step.Approve: Finish("approve later"); break;
        }
    }

    private void Secondary_Click(object sender, RoutedEventArgs e) => GoBack();

    public void GoBack()
    {
        if (!CanGoBack) return;
        BrowserSignIn.Cancel();
        Show(Current == Step.Sync ? Step.Music : Step.Welcome);
    }

    private void Root_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Escape) return;
        if (BrowserSignIn.IsWaiting) BrowserSignIn.Cancel();
        else if (ServerPanel.Visibility == Visibility.Visible) ToggleServer(false);
        else if (CanGoBack) GoBack();
        else return;
        e.Handled = true;
    }

    private void Finish(string how)
    {
        if (_finished) return;
        _finished = true;
        _generation++;
        BrowserSignIn.Cancel();
        _resendTimer.Stop();
        App.Services.Provider.PropertyChanged -= Provider_PropertyChanged;
        if (_sync is { } sync)
        {
            sync.Account.PropertyChanged -= Account_PropertyChanged;
            sync.Service.PropertyChanged -= Service_PropertyChanged;
        }
        var settings = App.Services.Settings;
        settings.Values.WelcomeDone = true;
        settings.Values.OnboardingResume = null;
        settings.SaveNow();
        Log.Info($"onboarding: finished at {Current} ({how})");
        Finished?.Invoke();
    }

    // MARK: Your music

    private void Provider_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(IMusicProvider.AuthStatus)) DispatcherQueue.TryEnqueue(UpdateYouTube);
    }

    private void UpdateYouTube()
    {
        var status = App.Services.Provider.AuthStatus;
        var signedIn = status.IsSignedIn;
        var ready = signedIn || _youTubeChosen;
        YouTubeDoneIcon.Visibility = Visible(ready);
        YouTubeStatus.Text = signedIn
            ? $"Signed in as {status.Account?.Name ?? "your Google account"}"
            : _youTubeChosen
                ? "Ready to play without an account. You can sign in any time."
                : "Works without an account. Sign in to bring your library, likes and playlists.";
        YouTubeButtons.Visibility = Visible(!signedIn);
        // Signed-out YouTube Music counts as ready (flow.md), so the step never blocks: its footer goes on without an account.
        // flow.md's "Use without an account" is the step's one guest action, in the footer; after a sign-in it reads Continue.
        if (Current == Step.Music) SetFooter(ready ? "Continue" : "Use without an account", accent: true, enabled: true);
    }

    /// <summary>The two buttons sit side by side while they fit (large text sizes stack them).</summary>
    private void YouTubeButtons_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        var available = YouTubeStatus.ActualWidth;
        if (available <= 0) return;
        YouTubeSignInButton.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
        var orientation = YouTubeSignInButton.DesiredSize.Width > available + 1 ? Orientation.Vertical : Orientation.Horizontal;
        if (YouTubeButtons.Orientation != orientation) YouTubeButtons.Orientation = orientation;
    }

    private void YouTubeSignIn_Click(object sender, RoutedEventArgs e)
    {
        Log.Info("onboarding: YouTube Music sign-in");
        ShellPage.Current.SignInToYouTube();
    }

    /// <summary>YouTube Music without an account: ready, and on to Sync in the same tap.</summary>
    private void UseYouTubeSignedOut()
    {
        _youTubeChosen = true;
        Log.Info("onboarding: YouTube Music without an account");
        UpdateYouTube();
        Show(Step.Sync);
    }

    // MARK: Sync

    private AccountService? Account => _sync?.Account;

    private void Account_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (Current == Step.Sync && e.PropertyName is nameof(AccountService.SocialProviders) or nameof(AccountService.Server) or nameof(AccountService.ServerProblem))
            UpdateSync();
    }

    private void UpdateSync()
    {
        if (Account is not { } account)
        {
            SignInChoices.Visibility = Visibility.Collapsed;
            return;
        }
        // Before the server's sign-in settings load, both buttons show (the hosted server has both); after, only what it has on.
        UpdateChoices();
        var server = account.Server;
        ServerInUse.Visibility = Visible(server.IsCustom || _serverSwitched);
        ServerInUse.Text = $"Signing in on {server.Url.Host}";
        // flow.md's line, naming the server actually in use, and who handles sign-in.
        PrivacyLine.Text = server.IsCustom || _serverSwitched
            ? $"{server.Url.Host} sees when you play and pause, never what you play. Songs, queues and searches are encrypted on your devices. Sign-in goes through the Clerk app this server uses."
            : $"{Name}'s server sees when you play and pause, never what you play. Songs, queues and searches are encrypted on your devices. Sign-in is handled by Clerk.";
        ServerLinkText.Text = server.IsCustom || _serverSwitched ? "Use a different server" : "Use your own server";
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(ServerLink, ServerLinkText.Text);
        if (account.ServerProblem is { } problem && !_busy && !SignInError.IsOpen)
            ShowError(account.Server.IsCustom ? $"Can't reach {account.Server.Url.Host}" : $"Can't reach {Name}'s server", problem, warning: true);
        SetBusy(_busy);
    }

    private bool _signedInShown;

    /// <summary>
    /// Which sign-in parts show: one thing at a time, so the form fits without scrolling half a button out of view. While
    /// a code is on its way the Apple and Google buttons step aside (Use a different email brings them back); while the
    /// server panel is open, so does the whole sign-in (closing it brings it back).
    /// </summary>
    private void UpdateChoices()
    {
        if (Account is not { } account) return;
        IReadOnlyList<ClerkOAuthProvider> social = account.IsReady ? account.SocialProviders : [ClerkOAuthProvider.Apple, ClerkOAuthProvider.Google];
        var serverOpen = ServerPanel.Visibility == Visibility.Visible;
        var choosing = !_signedInShown && !serverOpen && _challenge is null;
        // While the browser sign-in waits, the email row steps aside too (the buttons stay, dimmed, to show what's running).
        var browserWaiting = BrowserBar.IsOpen;
        AppleButton.Visibility = Visible(choosing && social.Contains(ClerkOAuthProvider.Apple));
        GoogleButton.Visibility = Visible(choosing && social.Contains(ClerkOAuthProvider.Google));
        OrDivider.Visibility = Visible(choosing && !browserWaiting && social.Count > 0);
        EmailPanel.Visibility = Visible(choosing && !browserWaiting);
        CodePanel.Visibility = Visible(!_signedInShown && !serverOpen && _challenge is not null);
    }

    private void SetBusy(bool busy)
    {
        _busy = busy;
        foreach (var control in new Control[] { AppleButton, GoogleButton, EmailBox, ResendButton, ChangeEmailButton, CodeBox, ServerLink, CheckServerButton, ServerBox, UseServerButton })
            control.IsEnabled = !busy;
        if (_restartRequired)
        {
            // Signing in now would sign the account in on a server this PC's sync isn't using.
            foreach (var control in new Control[] { AppleButton, GoogleButton, EmailBox, SendCodeButton, CodeBox, VerifyButton, ServerLink })
                control.IsEnabled = false;
            return;
        }
        SendCodeButton.IsEnabled = !busy && LooksLikeEmail(EmailBox.Text);
        VerifyButton.IsEnabled = !busy && Digits(CodeBox.Text).Length == 6;
        CheckServerButton.IsEnabled = !busy && ServerBox.Text.Trim().Length > 0;
        ResendButton.IsEnabled = !busy && _resendLeft == 0;
        SignInProgress.Visibility = Visible(busy && !BrowserBar.IsOpen);
        ShellPage.Current.OnboardingStepChanged();
    }

    private static bool LooksLikeEmail(string text)
    {
        var t = text.Trim();
        var at = t.IndexOf('@');
        return at > 0 && t.IndexOf('.', at) > at + 1 && !t.EndsWith('.') && !t.Contains(' ');
    }

    private static string Digits(string text) => new(text.Where(char.IsAsciiDigit).ToArray());

    private void ShowError(string title, string message, bool warning = false)
    {
        SignInError.Severity = warning ? InfoBarSeverity.Warning : InfoBarSeverity.Error;
        SignInError.Title = title;
        SignInError.Message = message;
        SignInError.IsOpen = true;
    }

    private void EmailBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        SendCodeButton.IsEnabled = !_busy && LooksLikeEmail(EmailBox.Text);
        if (SignInError.IsOpen && SignInError.Severity == InfoBarSeverity.Error) SignInError.IsOpen = false;
    }

    private void EmailBox_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter) return;
        e.Handled = true;
        if (SendCodeButton.IsEnabled) _ = SendCodeAsync();
        else if (EmailBox.Text.Trim().Length > 0) ShowError("Check the email address", "Enter the whole address, like name@example.com.");
    }

    private void SendCode_Click(object sender, RoutedEventArgs e) => _ = SendCodeAsync();

    private async Task SendCodeAsync()
    {
        if (Account is not { } account || _busy) return;
        var generation = _generation;
        var email = EmailBox.Text.Trim();
        SignInError.IsOpen = false;
        SetBusy(true);
        try
        {
            var challenge = await account.StartEmailAsync(email);
            if (generation != _generation) return;
            _challenge = challenge;
            ShowCodeStep(challenge.Email);
            Log.Info($"onboarding: email code sent ({challenge.Kind})");
        }
        catch (Exception e)
        {
            if (generation != _generation) return;
            Log.Error($"onboarding: send code: {e.GetType().Name}");
            ShowError("Couldn't send a code", Explain(e));
        }
        finally
        {
            if (generation == _generation) SetBusy(false);
        }
        if (generation == _generation && _challenge is not null) CodeBox.Focus(FocusState.Programmatic);
    }

    private void ShowCodeStep(string email)
    {
        UpdateChoices();
        CodeSentText.Text = $"Enter the 6-digit code sent to {email}.";
        CodeBox.Text = "";
        StartResendCountdown();
    }

    private void StartResendCountdown()
    {
        _resendLeft = 30;
        TickResend(start: true);
        _resendTimer.Start();
    }

    private void TickResend(bool start = false)
    {
        if (!start) _resendLeft = Math.Max(0, _resendLeft - 1);
        ResendButton.Content = _resendLeft > 0 ? $"Resend code in {_resendLeft} s" : "Resend code";
        ResendButton.IsEnabled = _resendLeft == 0 && !_busy;
        if (_resendLeft == 0) _resendTimer.Stop();
    }

    private void CodeBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        var digits = Digits(CodeBox.Text);
        VerifyButton.IsEnabled = !_busy && digits.Length == 6;
        if (SignInError.IsOpen && SignInError.Severity == InfoBarSeverity.Error && digits.Length > 0) SignInError.IsOpen = false;
        // Six digits typed or pasted ("482 913" too): sign in at once.
        if (digits.Length == 6 && !_busy && CodeBox.Text.Trim().Length <= 7) _ = VerifyAsync();
    }

    private void CodeBox_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter) return;
        e.Handled = true;
        if (VerifyButton.IsEnabled) _ = VerifyAsync();
    }

    private void Verify_Click(object sender, RoutedEventArgs e) => _ = VerifyAsync();

    private async Task VerifyAsync()
    {
        if (Account is not { } account || _challenge is not { } challenge || _busy) return;
        var generation = _generation;
        SignInError.IsOpen = false;
        SetBusy(true);
        try
        {
            var user = await account.VerifyEmailAsync(challenge, Digits(CodeBox.Text));
            Log.Info("onboarding: signed in with an email code");
            await AfterSignInAsync(user, generation);
        }
        catch (Exception e)
        {
            if (generation != _generation || _finished) return;
            Log.Error($"onboarding: verify: {e.GetType().Name} {(e as ClerkException)?.Code}");
            var (title, message) = e switch
            {
                ClerkException { Code: "form_code_incorrect" } => ("That code isn't right", "Check the latest email and try again, or send a new code."),
                ClerkException { Code: "verification_expired" } => ("That code expired", "Send a new code and enter it within ten minutes."),
                ClerkException { Code: "verification_failed" } => ("Too many tries", "Send a new code, then enter it."),
                _ => ("Couldn't sign in", Explain(e)),
            };
            ShowError(title, message);
            SetBusy(false);
            CodeBox.SelectAll();
            CodeBox.Focus(FocusState.Programmatic);
        }
    }

    private void Resend_Click(object sender, RoutedEventArgs e) => _ = ResendAsync();

    private async Task ResendAsync()
    {
        if (Account is not { } account || _challenge is not { } challenge || _busy) return;
        var generation = _generation;
        SignInError.IsOpen = false;
        SetBusy(true);
        try
        {
            _challenge = await account.StartEmailAsync(challenge.Email);
            if (generation != _generation) return;
            CodeSentText.Text = $"A new code is on its way to {challenge.Email}.";
            CodeBox.Text = "";
            StartResendCountdown();
        }
        catch (Exception e)
        {
            if (generation == _generation) ShowError("Couldn't send a new code", Explain(e));
        }
        finally
        {
            if (generation == _generation) SetBusy(false);
        }
        if (generation == _generation) CodeBox.Focus(FocusState.Programmatic);
    }

    private void ChangeEmail_Click(object sender, RoutedEventArgs e)
    {
        _challenge = null;
        _resendTimer.Stop();
        _resendLeft = 0;
        SignInError.IsOpen = false;
        UpdateChoices();
        EmailBox.Focus(FocusState.Programmatic);
        EmailBox.SelectAll();
    }

    private void Apple_Click(object sender, RoutedEventArgs e) => _ = BrowserAsync(ClerkOAuthProvider.Apple);

    private void Google_Click(object sender, RoutedEventArgs e) => _ = BrowserAsync(ClerkOAuthProvider.Google);

    private async Task BrowserAsync(ClerkOAuthProvider provider)
    {
        if (Account is not { } account || _busy) return;
        var generation = _generation;
        SignInError.IsOpen = false;
        SetBusy(true);
        try
        {
            var user = await BrowserSignIn.RunAsync(account, provider, opened: () =>
            {
                if (generation != _generation) return;
                BrowserBar.Title = $"Finish signing in with {provider.Name} in your browser";
                BrowserBar.Message = $"{Name} continues when you're done.";
                BrowserBar.IsOpen = true;
                UpdateChoices();
                BrowserCancelButton.IsEnabled = BrowserReopenButton.IsEnabled = true;
                SignInProgress.Visibility = Visibility.Collapsed;
                BrowserCancelButton.Focus(FocusState.Programmatic);
            });
            BrowserBar.IsOpen = false;
            App.MainWindow?.BringToFront();
            await AfterSignInAsync(user, generation);
        }
        catch (Exception e)
        {
            BrowserBar.IsOpen = false;
            UpdateChoices();
            if (generation != _generation || _finished) return;
            Log.Info($"onboarding: {provider.Name} sign-in ended: {e.GetType().Name} {(e as ClerkException)?.Code}");
            App.MainWindow?.BringToFront();
            if (BrowserSignIn.Describe(e, provider) is { } message) ShowError($"Couldn't sign in with {provider.Name}", message);
            SetBusy(false);
            (provider == ClerkOAuthProvider.Apple ? AppleButton : GoogleButton).Focus(FocusState.Programmatic);
        }
    }

    private void BrowserCancel_Click(object sender, RoutedEventArgs e) => BrowserSignIn.Cancel();

    /// <summary>The browser page was closed or lost: the same sign-in, opened again.</summary>
    private void BrowserReopen_Click(object sender, RoutedEventArgs e) => _ = BrowserSignIn.ReopenAsync();

    private static string Explain(Exception e) => BrowserSignIn.Describe(e) ?? "Try again.";

    /// <summary>Signed in: connect this PC, then Approve when another device holds the key, else Home.</summary>
    private async Task AfterSignInAsync(ClerkUser user, int generation)
    {
        var sync = _sync!;
        if (generation == _generation && !_finished)
        {
            SignedInBar.Title = $"Signed in as {user.DisplayName}";
            SignedInBar.Message = "Connecting this PC…";
            SignedInBar.IsOpen = true;
            BrowserBar.IsOpen = false;
            _signedInShown = true;
            UpdateChoices();
        }
        // The sign-in counts even if the listener moved on meanwhile.
        await sync.DidSignInAsync();
        if (generation != _generation || _finished) return;
        var service = sync.Service;
        var deadline = DateTime.UtcNow.AddSeconds(10);
        // The first device of an account makes the key at once; a later one asks the device that has it.
        while (DateTime.UtcNow < deadline && service.KeyStatus is not KeyStatus.Available && !(service.IsRegistered && service.KeyHolders.Count > 0))
        {
            await Task.Delay(250);
            if (generation != _generation || _finished) return;
        }
        Log.Info($"onboarding: after sign-in, key {SyncHub.Describe(service.KeyStatus)}, {service.KeyHolders.Count} holder(s)");
        if (service.KeyStatus is KeyStatus.Available || service.KeyHolders.Count == 0)
        {
            Finish("signed in");
            return;
        }
        _approveNeeded = true;
        SetBusy(false);
        Show(Step.Approve);
    }

    // MARK: Use your own server

    private void ServerLink_Click(object sender, RoutedEventArgs e) => ToggleServer(ServerPanel.Visibility != Visibility.Visible);

    private void ToggleServer(bool open)
    {
        ServerPanel.Visibility = Visible(open);
        UpdateChoices();
        ServerChevron.Glyph = open ? "" : "";
        if (open)
        {
            if (ServerBox.Text.Length == 0 && Account?.Server is { IsCustom: true } custom) ServerBox.Text = custom.Url.AbsoluteUri;
            ServerBox.Focus(FocusState.Programmatic);
            _ = BringIntoViewSoonAsync(ServerPanel);
        }
        else
        {
            ServerLink.Focus(FocusState.Programmatic);
            StepScroller.ChangeView(null, 0, null);
        }
    }

    private void ServerBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        CheckServerButton.IsEnabled = !_busy && ServerBox.Text.Trim().Length > 0;
        if (_checkedServer is not null || ServerResult.IsOpen)
        {
            _checkedServer = null;
            ServerResult.IsOpen = false;
        }
    }

    private void ServerBox_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter) return;
        e.Handled = true;
        if (_checkedServer is not null && UseServerButton.IsEnabled) _ = UseServerAsync();
        else if (CheckServerButton.IsEnabled) _ = CheckServerAsync();
    }

    private void CheckServer_Click(object sender, RoutedEventArgs e) => _ = CheckServerAsync();

    private async Task CheckServerAsync()
    {
        if (Account is not { } account || _busy) return;
        var generation = _generation;
        var text = ServerBox.Text.Trim();
        ServerResult.IsOpen = false;
        _checkedServer = null;
        ServerCheckingText.Text = $"Checking {(SyncServer.Parse(text)?.Host ?? text)}…";
        ServerChecking.Visibility = Visibility.Visible;
        SetBusy(true);
        try
        {
            var url = await account.CheckServerAsync(text);
            if (generation != _generation) return;
            _checkedServer = url;
            ServerResult.Severity = InfoBarSeverity.Success;
            ServerResult.Title = "Ready to use";
            ServerResult.Message = $"{url.Host} is reachable and set up for sign-in.";
            UseServerButton.Visibility = Visibility.Visible;
            Log.Info("onboarding: server check passed");
        }
        catch (Exception e)
        {
            if (generation != _generation) return;
            ServerResult.Severity = InfoBarSeverity.Error;
            ServerResult.Title = "Can't use this server";
            ServerResult.Message = Log.Redact(e.Message.Split('\n', 2)[0]);
            UseServerButton.Visibility = Visibility.Collapsed;
            Log.Info($"onboarding: server check failed: {e.GetType().Name}");
        }
        finally
        {
            if (generation == _generation)
            {
                ServerChecking.Visibility = Visibility.Collapsed;
                ServerResult.IsOpen = true;
                SetBusy(false);
                // The result (and its Use This Server button) can land below the fold: bring it up once it has its height.
                _ = BringIntoViewSoonAsync(ServerPanel);
            }
        }
        if (generation == _generation) (_checkedServer is not null ? (Control)UseServerButton : ServerBox).Focus(FocusState.Programmatic);
    }

    private async Task BringIntoViewSoonAsync(FrameworkElement element)
    {
        await Task.Delay(120);
        var bottom = element.TransformToVisual(StepHost).TransformPoint(new Windows.Foundation.Point(0, element.ActualHeight)).Y + 16;
        var overflow = bottom - (StepScroller.VerticalOffset + StepScroller.ViewportHeight);
        if (overflow > 0) StepScroller.ChangeView(null, StepScroller.VerticalOffset + overflow, null);
    }

    /// <summary>Stops waiting for a slow server (its answer, when it comes, is ignored).</summary>
    private void CancelCheck_Click(object sender, RoutedEventArgs e)
    {
        _generation++;
        ServerChecking.Visibility = Visibility.Collapsed;
        SetBusy(false);
        ServerBox.Focus(FocusState.Programmatic);
        Log.Info("onboarding: server check cancelled");
    }

    private void UseServer_Click(object sender, RoutedEventArgs e) => _ = UseServerAsync();

    private async Task UseServerAsync()
    {
        if (_sync is not { } sync || _checkedServer is not { } url || _busy) return;
        var generation = _generation;
        SetBusy(true);
        try
        {
            if (sync.NeedsRestartToUse(url))
            {
                // Sync on this PC is tied to one server for the life of the process: switch, then start again on this step.
                // The switch is committed once it starts: leaving now would strand the account on a server sync can't use.
                PrimaryButton.IsEnabled = false;
                App.Services.Settings.Values.OnboardingResume = "sync";
                App.Services.Settings.SaveNow();
                await sync.SwitchServerAsync(url, quiet: true);
                if (_finished) return;
                Log.Info("onboarding: switched servers; restarting to use it");
                var failure = Microsoft.Windows.AppLifecycle.AppInstance.Restart("");
                // Still here: Restart failed. Sign-in stays off until the app is reopened on the new server; Not Now still works.
                _restartRequired = true;
                PrimaryButton.IsEnabled = true;
                Log.Error($"onboarding: restart failed ({failure})");
                ServerResult.Severity = InfoBarSeverity.Informational;
                ServerResult.Title = $"Restart {Name} to finish";
                ServerResult.Message = $"{Name} couldn't restart by itself ({failure}). Close it and open it again; setup continues here.";
                UseServerButton.Visibility = Visibility.Collapsed;
                return;
            }
            await sync.SwitchServerAsync(url, quiet: true);
            if (generation != _generation) return;
            _serverSwitched = true;
            _checkedServer = null;
            ServerResult.IsOpen = false;
            ServerBox.Text = "";
            ToggleServer(false);
            UpdateSync();
            Log.Info("onboarding: using the checked server");
        }
        catch (Exception e)
        {
            if (generation != _generation) return;
            ServerResult.Severity = InfoBarSeverity.Error;
            ServerResult.Title = "Couldn't switch servers";
            ServerResult.Message = Log.Redact(e.Message.Split('\n', 2)[0]);
            ServerResult.IsOpen = true;
        }
        finally
        {
            if (generation == _generation) SetBusy(false);
        }
        if (generation == _generation && ServerPanel.Visibility != Visibility.Visible)
            (AppleButton.Visibility == Visibility.Visible ? (Control)AppleButton : EmailBox).Focus(FocusState.Programmatic);
    }

    // MARK: Approve this PC

    private void Service_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (Current == Step.Approve && !_finished) UpdateApprove();
    }

    private string HolderName(SyncService service, KeyComparison? comparison = null) =>
        comparison?.HolderName ?? (service.KeyHolders is { Count: 1 } one ? one[0].Name : "your other device");

    private void UpdateApprove()
    {
        if (_sync?.Service is not { } service) return;
        var status = service.KeyStatus;
        var comparison = (status as KeyStatus.Comparing)?.Comparison;
        var holder = HolderName(service, comparison);
        // Service changes come for many reasons (devices, playback): redraw only when what this step shows changes, so the
        // buttons keep their focus.
        var shape = $"{SyncHub.Describe(status)}|{holder}";
        if (shape == _approveShape) return;
        _approveShape = shape;
        StepBody.Text = $"Open {Name} on {holder} to approve {Here}.";
        ApproveProblem.IsOpen = false;
        ApproveWaiting.Visibility = Visibility.Collapsed;
        ApproveWaitingHint.Visibility = Visibility.Collapsed;
        ApproveCompare.Visibility = Visibility.Collapsed;
        switch (status)
        {
            case KeyStatus.Available:
                ApproveWaitingText.Text = "This PC is approved.";
                ApproveWaiting.Visibility = Visibility.Visible;
                if (_approvedShown) break;
                _approvedShown = true;
                var generation = _generation;
                DispatcherQueue.TryEnqueue(async () =>
                {
                    await Task.Delay(900);
                    if (generation == _generation) Finish("approved");
                });
                break;
            case KeyStatus.Comparing c:
                _shownComparison = c.Comparison;
                ApproveCode.Text = KeyDialogs.FormatCode(c.Comparison.Code);
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(ApproveCode, $"Code {string.Join(' ', c.Comparison.Code.ToCharArray())}");
                ApproveCompare.Visibility = Visibility.Visible;
                var answered = c.Comparison.Confirmed;
                ApproveAnswers.Visibility = Visible(!answered);
                ApproveSpinner.Visibility = Visible(answered);
                ApproveSpinner.IsActive = answered;
                ApproveInstructions.Text = (c.Comparison.Allowed, answered) switch
                {
                    (false, false) => $"{holder} shows a code too. If it's the same, choose Allow there and Codes Match here.",
                    (false, true) => $"Now choose Allow on {holder}.",
                    (true, false) => $"{holder} allowed {Here}. Choose Codes Match if it showed this same code.",
                    _ => "Your YouTube Music and Spotify sign-ins arrive in a moment.",
                };
                break;
            case KeyStatus.Denied:
                ShowApproveProblem($"{holder} didn't allow {Here}", "Ask again, then choose Allow on the other device when both show the same code.");
                break;
            case KeyStatus.Failed f:
                ShowApproveProblem("This PC wasn't approved", f.Message);
                break;
            case KeyStatus.Mismatch or KeyStatus.Outdated:
                ShowApproveProblem("This PC has an old key", "Ask again to replace it with your account's current key.");
                break;
            default:
                ApproveWaitingText.Text = $"Waiting for {holder}…";
                ApproveWaiting.Visibility = Visibility.Visible;
                ApproveWaitingHint.Text = $"Nothing on {holder}? Open {Name} there and keep it online; it asks you to allow this PC.";
                ApproveWaitingHint.Visibility = Visibility.Visible;
                break;
        }
    }

    private void ShowApproveProblem(string title, string message)
    {
        ApproveProblem.Title = title;
        ApproveProblem.Message = message;
        ApproveProblem.IsOpen = true;
    }

    private void CodesMatch_Click(object sender, RoutedEventArgs e)
    {
        if (_sync?.Service is not { } service || _shownComparison is not { } shown) return;
        service.ConfirmKeyCode(shown);
        Log.Info($"onboarding: codes match ({shown.Code})");
    }

    private void CodesDontMatch_Click(object sender, RoutedEventArgs e)
    {
        if (_sync?.Service is not { } service || _shownComparison is not { } shown) return;
        service.RejectKeyCode(shown);
        Log.Info("onboarding: codes don't match");
    }

    private async void AskAgain_Click(object sender, RoutedEventArgs e)
    {
        if (_sync?.Service is not { } service) return;
        AskAgainButton.IsEnabled = false;
        try { await service.RequestKeyAgainAsync(); }
        catch (Exception ex) { ShowApproveProblem("Couldn't ask again", Log.Redact(ex.Message.Split('\n', 2)[0])); }
        finally { AskAgainButton.IsEnabled = true; }
    }

#if DEBUG
    /// <summary>Debug self-test: the approve step with sample data, for screenshots without a second device.</summary>
    public void PreviewApprove(string holder, string code)
    {
        _approveNeeded = true;
        Show(Step.Approve);
        StepBody.Text = $"Open {Name} on {holder} to approve {Here}.";
        ApproveCode.Text = KeyDialogs.FormatCode(code);
        ApproveInstructions.Text = $"{holder} shows a code too. If it's the same, choose Allow there and Codes Match here.";
        ApproveWaiting.Visibility = Visibility.Collapsed;
        ApproveCompare.Visibility = Visibility.Visible;
        ApproveAnswers.Visibility = Visibility.Visible;
    }
#endif
}
