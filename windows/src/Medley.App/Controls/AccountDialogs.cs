using System.ComponentModel;
using Medley.App.Services;
using Medley.Sync;
using Medley.Sync.Account;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Medley.App;

/// <summary>
/// Sign in to OpenMusic: an email and the one-time code Clerk sends, or Apple or Google in the system browser when the
/// server's Clerk app has them on (<see cref="BrowserSignIn"/>). Returns true once signed in.
/// </summary>
public static class MedleySignInDialog
{
    public static Task<bool> ShowAsync(SyncHub sync) => ShowAsync(sync, preview: null);

#if DEBUG
    /// <summary>Debug self-test: the same dialog with no account behind it, on its email (<c>email</c>) or code
    /// (<c>code</c>) step, for screenshots. Its buttons only move between the two steps.</summary>
    public static Task ShowPreviewAsync(string step) => ShowAsync(null, step);
#endif

    private static async Task<bool> ShowAsync(SyncHub? sync, string? preview)
    {
        var account = sync?.Account;
        ContentDialog? dialogRef = null;
        ClerkEmailChallenge? challenge = null;
        var signedIn = false;

        var intro = new TextBlock
        { Style = Ui.Style("MedleySecondaryTextStyle"),
            Text = $"Your queue, what's playing and your YouTube Music sign-in follow you between {Medley.Core.ProductInfo.Name} on this PC, your Mac and your iPhone.",
            TextWrapping = TextWrapping.Wrap,
        };
        var email = new TextBox { Header = "Email", PlaceholderText = "you@example.com", InputScope = Scope(Microsoft.UI.Xaml.Input.InputScopeNameValue.EmailSmtpAddress) };
        AutomationProperties.SetAutomationId(email, "SignInEmail");
        var code = new TextBox { Header = "Code", PlaceholderText = "6 digits", MaxLength = 8, Visibility = Visibility.Collapsed, InputScope = Scope(Microsoft.UI.Xaml.Input.InputScopeNameValue.Number) };
        AutomationProperties.SetAutomationId(code, "SignInCode");
        var sent = new TextBlock { TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
        // On the code step: fix the address, or ask for another code (Clerk sends a new one for the same address).
        var changeEmail = new HyperlinkButton { Content = "Change email", Padding = new Thickness(0, 2, 0, 2) };
        AutomationProperties.SetAutomationId(changeEmail, "SignInChangeEmail");
        var resend = new HyperlinkButton { Content = "Resend code", Padding = new Thickness(0, 2, 0, 2) };
        AutomationProperties.SetAutomationId(resend, "SignInResend");
        var codeLinks = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16, Visibility = Visibility.Collapsed };
        codeLinks.Children.Add(changeEmail);
        codeLinks.Children.Add(resend);
        var error = new InfoBar { Severity = InfoBarSeverity.Error, IsClosable = false, IsOpen = false };
        AutomationProperties.SetAutomationId(error, "SignInError");
        var progress = new ProgressBar { IsIndeterminate = true, Visibility = Visibility.Collapsed };
        var server = new TextBlock
        {
            Text = account?.Server.IsCustom == true ? $"Server: {account.Server.Url.Host}" : $"Server: {Medley.Core.ProductInfo.Name}",
            Style = Ui.Style("MedleyTertiaryCaptionStyle"),
        };
        var panel = new StackPanel { Spacing = 12, Width = 380 };
        panel.Children.Add(intro);
        panel.Children.Add(email);
        panel.Children.Add(sent);
        panel.Children.Add(code);
        panel.Children.Add(codeLinks);
        IReadOnlyList<ClerkOAuthProvider> social = account is null || !account.IsReady ? [ClerkOAuthProvider.Apple, ClerkOAuthProvider.Google] : account.SocialProviders;
        var socialButtons = new List<Button>();
        foreach (var provider in social.Where(p => p == ClerkOAuthProvider.Apple || p == ClerkOAuthProvider.Google))
        {
            var mark = provider == ClerkOAuthProvider.Apple ? Controls.BrandMarks.Apple(16) : Controls.BrandMarks.Google(15);
            mark.HorizontalAlignment = HorizontalAlignment.Left;
            mark.VerticalAlignment = VerticalAlignment.Center;
            var content = new Grid();
            content.Children.Add(mark);
            content.Children.Add(new TextBlock { Text = $"Continue with {provider.Name}", HorizontalAlignment = HorizontalAlignment.Center });
            var button = new Button { HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch, Content = content, MinHeight = 34 };
            AutomationProperties.SetAutomationId(button, $"SignIn{provider.Name}");
            AutomationProperties.SetName(button, $"Continue with {provider.Name}");
            button.Click += async (_, _) =>
            {
                if (account is null) return;
                error.IsOpen = false;
                progress.Visibility = Visibility.Visible;
                foreach (var b in socialButtons) b.IsEnabled = false;
                try
                {
                    await BrowserSignIn.RunAsync(account, provider, opened: () =>
                    {
                        sent.Text = $"Finish signing in with {provider.Name} in your browser. {Medley.Core.ProductInfo.Name} continues when you're done.";
                        sent.Visibility = Visibility.Visible;
                    });
                    signedIn = true;
                    App.MainWindow?.BringToFront();
                    if (ReferenceEquals(Dialogs.Current, dialogRef)) dialogRef?.Hide();
                }
                catch (Exception e)
                {
                    sent.Visibility = Visibility.Collapsed;
                    if (BrowserSignIn.Describe(e, provider) is { } message)
                    {
                        error.Title = $"Couldn't sign in with {provider.Name}";
                        error.Message = message;
                        error.IsOpen = true;
                    }
                }
                finally
                {
                    progress.Visibility = Visibility.Collapsed;
                    foreach (var b in socialButtons) b.IsEnabled = true;
                }
            };
            socialButtons.Add(button);
        }
        if (socialButtons.Count > 0)
        {
            panel.Children.Add(new TextBlock { Style = Ui.Style("MedleyTertiaryCaptionStyle"), Text = "or", HorizontalAlignment = HorizontalAlignment.Center });
            foreach (var b in socialButtons) panel.Children.Add(b);
        }
        panel.Children.Add(progress);
        panel.Children.Add(error);
        panel.Children.Add(server);

        var dialog = new ContentDialog
        {
            Title = $"Sign in to {Medley.Core.ProductInfo.Name}",
            Content = panel,
            PrimaryButtonText = "Send Code",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            IsPrimaryButtonEnabled = false,
        };
        AutomationProperties.SetAutomationId(dialog, "MedleySignInDialog");
        dialogRef = dialog;
        changeEmail.Click += (_, _) =>
        {
            challenge = null;
            email.IsEnabled = true;
            sent.Visibility = code.Visibility = codeLinks.Visibility = Visibility.Collapsed;
            code.Text = "";
            dialog.PrimaryButtonText = "Send Code";
            dialog.IsPrimaryButtonEnabled = email.Text.Contains('@');
            email.Focus(FocusState.Programmatic);
        };
        resend.Click += async (_, _) =>
        {
            if (account is null) return;
            resend.IsEnabled = false;
            error.IsOpen = false;
            try
            {
                challenge = await account.StartEmailAsync(email.Text.Trim());
                sent.Text = $"A new code is on its way to {challenge.Email}.";
            }
            catch (Exception e)
            {
                ShowError(error, e);
            }
            // Clerk limits how often codes go out; give the next one a moment.
            await Task.Delay(TimeSpan.FromSeconds(30));
            resend.IsEnabled = true;
        };
        email.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = challenge is null ? email.Text.Contains('@') : code.Text.Trim().Length >= 6;
        code.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = code.Text.Trim().Length >= 6;
        dialog.PrimaryButtonClick += async (d, args) =>
        {
            // Stay open across the steps; close only once signed in.
            args.Cancel = true;
            var deferral = args.GetDeferral();
            error.IsOpen = false;
            progress.Visibility = Visibility.Visible;
            d.IsPrimaryButtonEnabled = false;
            try
            {
                if (account is null)
                {
                    ShowCodeStep(email.Text.Trim());
                }
                else if (challenge is null)
                {
                    challenge = await account.StartEmailAsync(email.Text.Trim());
                    ShowCodeStep(challenge.Email);
                }
                else
                {
                    await account.VerifyEmailAsync(challenge, code.Text.Trim());
                    signedIn = true;
                    args.Cancel = false;
                }
            }
            catch (Exception e)
            {
                ShowError(error, e);
            }
            finally
            {
                progress.Visibility = Visibility.Collapsed;
                d.IsPrimaryButtonEnabled = challenge is null && account is not null ? email.Text.Contains('@') : code.Text.Trim().Length >= 6;
                deferral.Complete();
            }
        };
        void ShowCodeStep(string address)
        {
            email.IsEnabled = false;
            sent.Text = $"Enter the code sent to {address}.";
            sent.Visibility = Visibility.Visible;
            code.Visibility = Visibility.Visible;
            codeLinks.Visibility = Visibility.Visible;
            dialog.PrimaryButtonText = "Sign In";
            dialog.IsPrimaryButtonEnabled = code.Text.Trim().Length >= 6;
            code.Focus(FocusState.Programmatic);
        }
        if (preview is not null)
        {
            email.Text = "riley@example.com";
            dialog.IsPrimaryButtonEnabled = true;
            if (preview == "code") ShowCodeStep(email.Text);
        }
        await Dialogs.ShowAsync(dialog);
        // Cancelled (or done): a browser that comes back later completes nothing.
        BrowserSignIn.Cancel();
        return signedIn;
    }

    private static Microsoft.UI.Xaml.Input.InputScope Scope(Microsoft.UI.Xaml.Input.InputScopeNameValue value) =>
        new() { Names = { new Microsoft.UI.Xaml.Input.InputScopeName(value) } };

    private static void ShowError(InfoBar bar, Exception e)
    {
        bar.Title = e is ServerException or ClerkException ? "Couldn't sign in" : "Something went wrong";
        bar.Message = e.Message;
        bar.IsOpen = true;
        Log.Error($"medley sign-in: {e.GetType().Name}");
    }

    /// <summary>"Use your own server": one URL, checked before it's used. Returns the URL, or null for cancel.</summary>
    public static async Task ShowServerAsync(SyncHub sync)
    {
        var account = sync.Account;
        var url = new TextBox
        {
            Header = "Convex deployment URL",
            PlaceholderText = "https://your-deployment.convex.cloud",
            Text = account.Server.IsCustom ? account.Server.Url.AbsoluteUri : "",
            MinWidth = 380,
        };
        AutomationProperties.SetAutomationId(url, "ServerUrl");
        var help = new TextBlock
        { Style = Ui.Style("MedleySecondaryTextStyle"),
            Text = $"Run your own copy of {Medley.Core.ProductInfo.Name}'s sync server and enter its address. Everyone who uses it signs in there; {Medley.Core.ProductInfo.Name}'s server isn't used.",
            TextWrapping = TextWrapping.Wrap,
        };
        var error = new InfoBar { Severity = InfoBarSeverity.Error, IsClosable = false, IsOpen = false };
        var panel = new StackPanel { Spacing = 12, Width = 400 };
        panel.Children.Add(help);
        panel.Children.Add(url);
        panel.Children.Add(error);
        var dialog = new ContentDialog
        {
            Title = "Use your own server",
            Content = panel,
            PrimaryButtonText = "Use This Server",
            SecondaryButtonText = account.Server.IsCustom ? $"Use {Medley.Core.ProductInfo.Name}'s Server" : "",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        Uri? chosen = null;
        var useHosted = false;
        dialog.PrimaryButtonClick += async (d, args) =>
        {
            var deferral = args.GetDeferral();
            try
            {
                chosen = await account.CheckServerAsync(url.Text.Trim());
            }
            catch (Exception e)
            {
                args.Cancel = true;
                error.Title = "That server can't be used";
                error.Message = e.Message;
                error.IsOpen = true;
            }
            finally
            {
                deferral.Complete();
            }
        };
        dialog.SecondaryButtonClick += (_, _) => useHosted = true;
        var result = await Dialogs.ShowAsync(dialog);
        if (result == ContentDialogResult.Primary && chosen is not null) await sync.SwitchServerAsync(chosen);
        else if (useHosted) await sync.SwitchServerAsync(null);
    }
}

/// <summary>
/// The sign-in key exchange: on this PC as the new device, "Compare the codes"; on a device that holds the key, "Allow
/// <device> to use your YouTube Music and Spotify sign-ins?". Codes are shown as "482 913".
/// </summary>
public static class KeyDialogs
{
    private const string Here = "this PC";

    public static string FormatCode(string code) =>
        code.Length == 6 && code.All(char.IsAsciiDigit) ? $"{code[..3]} {code[3..]}" : code;

    private static TextBlock CodeText(string code, string id)
    {
        var text = new TextBlock
        {
            Text = FormatCode(code),
            FontSize = 40,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            CharacterSpacing = 60,
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 8, 0, 8),
            FontFamily = new FontFamily("Segoe UI Variable Display"),
        };
        AutomationProperties.SetAutomationId(text, id);
        return text;
    }

    private static Border CodeCard(TextBlock code) => new() { Style = Ui.Style("MedleyCodeCardStyle"), Child = code };

    /// <summary>This PC is new: compare its code with the one the holder shows.</summary>
    public static async Task CompareAsync(SyncHub? sync, KeyComparison comparison)
    {
        var service = sync?.Service;
        var instructions = new TextBlock { TextWrapping = TextWrapping.Wrap, Text = comparison.Instructions(Here) };
        var code = CodeText(comparison.Code, "CompareCode");
        var panel = new StackPanel { Spacing = 12, Width = 400 };
        var lead = new TextBlock
        { Style = Ui.Style("MedleySecondaryTextStyle"),
            Text = $"To use your YouTube Music and Spotify sign-ins here, {comparison.HolderName} has to allow this PC.",
            TextWrapping = TextWrapping.Wrap,
        };
        panel.Children.Add(lead);
        panel.Children.Add(CodeCard(code));
        panel.Children.Add(instructions);
        var dialog = new ContentDialog
        {
            Title = comparison.Title(Here),
            Content = panel,
            PrimaryButtonText = "Codes Match",
            SecondaryButtonText = "Codes Don't Match",
            CloseButtonText = "Later",
            DefaultButton = ContentDialogButton.Primary,
        };
        AutomationProperties.SetAutomationId(dialog, "CompareCodesDialog");
        // The comparison on screen. Codes Match and Codes Don't Match answer this one only; another exchange (another code
        // or holder) closes the dialog, and the next one opens for it.
        var shown = comparison;
        void Changed(object? s, PropertyChangedEventArgs e)
        {
            switch (service!.KeyStatus)
            {
                case KeyStatus.Comparing c when c.Comparison.Code == shown.Code && c.Comparison.HolderId == shown.HolderId:
                    shown = c.Comparison;
                    dialog.Title = c.Comparison.Title(Here);
                    instructions.Text = c.Comparison.Instructions(Here);
                    break;
                default:
                    dialog.Hide();
                    break;
            }
        }
        if (service is null)
        {
            await Dialogs.ShowAsync(dialog); // a Debug preview: nothing to answer
            return;
        }
        service.PropertyChanged += Changed;
        try
        {
            var result = await Dialogs.ShowAsync(dialog);
            if (result == ContentDialogResult.Primary)
            {
                service.ConfirmKeyCode(shown);
                Log.Info($"sync: codes match ({shown.Code})");
            }
            else if (result == ContentDialogResult.Secondary)
            {
                service.RejectKeyCode(shown);
                Log.Info("sync: codes don't match");
            }
        }
        finally
        {
            service.PropertyChanged -= Changed;
        }
    }

    /// <summary>This PC holds the key and another device asks for it.</summary>
    public static async Task AllowAsync(SyncHub? sync, KeyRequest request)
    {
        var name = request.Device.Name;
        var panel = new StackPanel { Spacing = 12, Width = 400 };
        panel.Children.Add(new TextBlock { Style = Ui.Style("MedleySecondaryTextStyle"), Text = "Code", HorizontalAlignment = HorizontalAlignment.Center, });
        panel.Children.Add(CodeCard(CodeText(request.Code, "AllowCode")));
        panel.Children.Add(new TextBlock
        {
            Text = $"Allow only if {name} shows this same code. It can then play with your accounts and sign in to them.",
            TextWrapping = TextWrapping.Wrap,
        });
        var dialog = new ContentDialog
        {
            Title = $"Allow {name} to use your YouTube Music and Spotify sign-ins?",
            Content = panel,
            PrimaryButtonText = "Allow",
            SecondaryButtonText = "Don't Allow",
            CloseButtonText = "Not Now",
            DefaultButton = ContentDialogButton.Close,
        };
        AutomationProperties.SetAutomationId(dialog, "AllowKeyDialog");
        var result = await Dialogs.ShowAsync(dialog);
        if (sync is null) return; // a Debug preview
        if (result == ContentDialogResult.Primary) await sync.AllowKeyAsync(request);
        else if (result == ContentDialogResult.Secondary) await sync.DenyKeyAsync(request);
    }
}
