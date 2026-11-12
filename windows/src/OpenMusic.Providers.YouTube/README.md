# OpenMusic.Providers.YouTube

YouTube Music for the Windows app (and any other .NET client), ported from `Sources/YouTubeMusicKit`. It talks to InnerTube, the API music.youtube.com itself uses. Cross-platform `net10.0` with no packages; it builds and tests on Linux.

## Using it from the app

```csharp
var provider = new YouTubeMusicProvider(new YouTubeMusicProviderOptions
{
    Store = new ProtectedFileCredentialStore(dataDir, new DpapiProtector()), // DPAPI, CurrentUser
    PlaybackEngineFactory = resolver => new MediaPlayerEngine(resolver),      // the app's engine
    ClearWebSignIn = () => signInWebView.ClearCookiesAsync(),                 // sign-out signs the web view out too
});
await provider.RestoreSessionAsync();
```

Create it on the UI thread: `PropertyChanged` (AuthStatus, Session, Capabilities) is raised on the context it was created on. Everything else is `IMusicProvider`.

`ISecretProtector` is the only Windows piece the app writes: `ProtectedData.Protect(bytes, null, DataProtectionScope.CurrentUser)` and `Unprotect`. The files hold the same JSON the Swift app keeps in its Keychain items `ytm.credentials` and `ytm.account`.

## Signing in with WebView2

`WebSignIn` has what the window needs:

1. Give the web view its own persistent profile folder and navigate to `WebSignIn.StartUrl` (Google's account chooser, then music.youtube.com). Keep WebView2's own user agent.
2. On each `NavigationCompleted` where `WebSignIn.IsLanding(webView.Source)`, read `CookieManager.GetCookiesAsync("https://music.youtube.com/")` once, map each cookie to `new WebCookie(c.Name, c.Value, c.Domain)`, and call `provider.SignInWithWebCookiesAsync(cookies)`.
3. A `null` result means it signed in (one confirmed account, or the channel picked on YouTube's own "Choose a channel" page). Otherwise show the returned `AccountChoiceList` and call `CommitSignInAsync(choice)`.
4. On close, call `DiscardPreparedSignIn()` and `CancelSignIn()`; ignore cookie reads that finish afterwards.

`WebSignIn.CredentialsFromCookies` keeps every cookie whose domain ends in `youtube.com`; a usable jar has `SAPISID` (or `__Secure-3PAPISID`) and `SID` (or `__Secure-1PSID` / `__Secure-3PSID`). `SwitchableAccountsAsync()` lists the accounts and brand channels the current sign-in can switch to.

## Sign-in sync

`YouTubeMusicSignInTransfer` exports and imports the payload OpenMusic Sync seals: byte-for-byte the Swift encoder's (`Fixtures/transfer_swift_*.json`, from macOS 27), so a Mac's sign-in works here and back. Give it an `IYouTubeMusicTransferStore` (DPAPI-protected file on Windows).

## Account operations

Everything that reads or changes the account runs one at a time on the provider's serial executor (`AccountOperations`, the design the Swift sync layer uses): restore, preparing a sign-in (`PrepareAccountsAsync`, `SwitchableAccountsAsync`, the whole `SignInWithWebCookiesAsync`), sign-in and `CommitSignInAsync`, sign-out, the transfer's import and export, and saving rotated cookies. An operation runs to completion, awaits included, before the next starts.

- A sign-in or sign-out supersedes everything older: queued operations never run, and the running one is cancelled and abandoned. A sign-out is never superseded itself, so a sign-in started meanwhile runs after it.
- Each operation applies its changes in one synchronous commit: saved cookies, installed cookies, status and session, and the transfer snapshot change together. A superseded operation's commit is refused, so it changes nothing after it resumes.
- The account summary (`ytm.account`) is written behind the commit that decided it, by one writer that always ends on the newest, so a stuck older write can't leave another account's summary next to the saved cookies.
- A choice commits only the login its own prepare confirmed; a newer prepare, `DiscardPreparedSignIn` or a sign-out drops the held one, and committing an older choice then throws `OperationCanceledException`.
- Catalog requests (browse, search, playback) never wait for it: they read the client's current credentials and go. Account-scoped reads (`AccountAsync`, `IsLikedAsync`, Home's personal shelves) follow the installed credentials, not the status, and ask again if the credentials were swapped before they answered. Likes, saves and follows go out bound to the credentials installed when they were called, and throw `PlaylistEditException` (account changed) instead of reaching another account.

## Playback

`YouTubeStreamResolver` asks VISIONOS, then ANDROID_VR, then IOS (the client that worked last goes first), checks each direct URL with a 2-byte range request, and on Windows prefers the progressive AAC/MP4 URL (`StreamPreference.Direct`), with the HLS audio rendition as the fallback. `PlayableStream.HttpHeaders` must go on every request for the URL (User-Agent).

## Testing

```bash
~/.dotnet/dotnet test windows/tests/OpenMusic.Providers.YouTube.Tests
DOTNET_ROOT=~/.dotnet windows/tests/OpenMusic.Providers.YouTube.Tests/tools/record-fixtures.sh <openmusic-probe>   # re-record live_* fixtures
```

`openmusic-probe ytm …` (windows/src/OpenMusic.Probe) exercises every call against the real service; `--cookies <file>` signs it in.
