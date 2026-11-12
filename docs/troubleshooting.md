# Troubleshooting

Fixes for the problems people hit most, then where the logs are and how to update or remove OpenMusic. For a problem not listed here, [open a bug report](https://github.com/opencoredev/openmusic/issues/new?template=bug-report.yml) with your platform, app version and a log excerpt.

## YouTube Music sign-in

**Google says the browser or app may not be secure, or the sign-in window stays blank.** Google sometimes refuses sign-ins from embedded windows. Try these in order:

1. Close the sign-in window and try again a few minutes later. Google's refusal is often temporary.
2. On the Mac, choose **Use a login from your browser** in the sign-in window. OpenMusic reads the YouTube sign-in from a Chromium-based browser where you are already signed in to music.youtube.com (Chrome, Arc, Brave, Edge and others). macOS asks once for permission to read that browser's "Safe Storage" key in your Keychain; click **Allow**.
3. Paste a browser cookie (Mac and iPhone), described next.

**Sign in with a browser cookie.** In OpenMusic's settings for YouTube Music (Mac: Settings › Services › YouTube Music), expand **Advanced**. In a desktop browser signed in to music.youtube.com, open the developer tools, select any request to `music.youtube.com` in the Network tab, copy the value of its `Cookie` request header, paste it into OpenMusic and click **Use Cookie**.

> **Warning:** that Cookie header grants full access to your Google account, not only YouTube Music. Paste it only into OpenMusic, never into a chat, an issue, a log or a website, and don't send it to anyone, including OpenMusic's maintainers. OpenMusic stores it in your Keychain and, if you use sync, also sends it end-to-end encrypted to your other approved devices so they are signed in too (the server can't read it). To make a leaked cookie useless, sign out of Google in that browser, or sign out of all sessions in your Google account's security settings.

**Windows: the sign-in window doesn't open or stays empty.** Google sign-in on Windows uses the Microsoft Edge WebView2 runtime. Windows 11 includes it. On Windows 10, install the Evergreen runtime from [Microsoft's WebView2 page](https://developer.microsoft.com/microsoft-edge/webview2/) and try again. Everything except your library works signed out.

## Spotify

**macOS asks "OpenMusic wants access to control Spotify".** Click **OK**: OpenMusic plays Spotify songs by controlling the Spotify app. If you clicked **Don't Allow**, turn it back on in System Settings › Privacy & Security › Automation › OpenMusic › Spotify.

**"No active Spotify device."** OpenMusic is set to play through Spotify Connect and no device is available. Open Spotify on a phone, computer or speaker signed in to the same account, play and pause any song there so Spotify lists it as active, then try again. On a Mac, installing the Spotify app lets OpenMusic play through it instead.

**"Spotify Connect playback needs Spotify Premium."** Spotify allows Connect playback only with Premium. On a Mac, the Spotify app route works with a Free account. The iPhone app can play Spotify only through Connect.

**Sign-in fails with an error from Spotify.** Spotify may have blocked the shared Client ID OpenMusic uses by default. Switch to [your own Client ID](spotify.md#use-your-own-client-id).

## Playback

**Songs stop playing, skip at once, or play only a few seconds.** OpenMusic reads YouTube's streams through unofficial interfaces, and YouTube changes them from time to time. Check [Releases](https://github.com/opencoredev/openmusic/releases) for a newer version, and look at the [open issues](https://github.com/opencoredev/openmusic/issues) to see whether it is already reported. If not, open a bug report with a log excerpt.

**One song never plays but others do.** Some songs aren't available in your country, are age-restricted, or are only playable with YouTube Premium. OpenMusic shows the reason YouTube gives and moves on.

**Lyrics are missing or out of time.** Lyrics come from YouTube Music first and LRCLIB second. Not every song has synced lyrics in either.

## Sync and device approval

**A new device says it is waiting for approval.** Open OpenMusic on a device that already has your sync key, such as the first device you signed in on. It shows "Allow <device>…?" with a six-digit code. Check that the code matches the one on the new device, then click **Allow** there and **Codes Match** on the new device. If you closed the alert, Settings › Account on that device has an **Allow…** button in the device's row. Until then the new device can see and control your other devices, but not what they play, and your settings and sign-ins don't sync to it.

**The codes don't match.** Tap **Codes Don't Match**. Different codes mean the exchange was changed on the way, or two attempts crossed. Tap **Ask Again** to start a new exchange with a new code. If codes keep not matching, stop and report it through [private vulnerability reporting](../SECURITY.md).

**"Your sign-ins changed while this device was away."** Another device replaced the sync key while this one was offline. Tap **Ask Again** and approve this device from one that has the current key.

**Every device that had the key is gone.** When the last device holding your sync key signs out or is removed, the key is lost and nobody can open what was encrypted with it. The server then deletes the synced settings and the synced service sign-ins become unreadable. The next device to notice makes a new key and uploads its own settings and sign-ins; approve the others from it. Your music services' own accounts and libraries are not affected.

**Sync doesn't connect to my own server.** See the troubleshooting section of [self-hosting](self-hosting.md#troubleshooting).

## iPhone in the background

iOS stops apps' network connections in the background unless they play audio. While OpenMusic plays, it stays connected, and other devices can see and control it. About 10 seconds after you pause and leave the app, it disconnects, and other devices can't send playback to it or control it until you open it again. Taking playback from another device (**Play on This iPhone**) works whenever you open the app.

## Logs

| Platform | Where | How to get it |
| --- | --- | --- |
| Windows | `%LOCALAPPDATA%\OpenMusic\logs\openmusic.log` | Paste that path into File Explorer's address bar. The log holds launches, player state changes, errors and the position every 5 seconds while playing. |
| Mac | The system log, subsystem `dev.openmusic.OpenMusic`; crash reports in `~/Library/Logs/DiagnosticReports` (`OpenMusic-*.ips`) | In Terminal: `log show --last 1h --predicate 'subsystem == "dev.openmusic.OpenMusic"'`. The app logs the notices it shows, such as playback and sign-in errors. |
| iPhone | Crash reports | Settings › Privacy & Security › Analytics & Improvements › Analytics Data, entries starting with `OpenMusic`. |

**Before you share a log**, read it and remove anything personal: your email address, account and device names, and anything that looks like a token, cookie or long random string. OpenMusic never writes tokens or cookies to its logs on purpose and redacts what it recognizes, but check anyway. Share only the lines around the problem.

## Updating

- **Windows:** quit OpenMusic, download the new zip from [Releases](https://github.com/opencoredev/openmusic/releases), and replace the old `OpenMusic` folder with the new one. Your sign-ins, queue and settings live in `%LOCALAPPDATA%\OpenMusic` and stay.
- **Mac:** pull the repository and build again ([CONTRIBUTING.md](../CONTRIBUTING.md#mac)). With the local signing identity, sign-ins stay across builds.
- **iPhone:** pull, build and run again from Xcode. A free Apple ID's builds stop opening after 7 days until you run them from Xcode again.

## Uninstalling

If you use sync, sign out of sync on the device first (Settings › Account › Sign Out), so the server removes it.

**Windows:**

1. Delete the `OpenMusic` folder you extracted.
2. Delete `%LOCALAPPDATA%\OpenMusic` (sign-ins, cache, queue, logs and the sign-in window's browser data).
3. Delete the Start menu shortcut the app created: `%APPDATA%\Microsoft\Windows\Start Menu\Programs\OpenMusic.lnk`.
4. Optional: in Registry Editor, delete `HKEY_CURRENT_USER\Software\Classes\openmusic`, the `openmusic:` link handler the app registers for itself.

**Mac:**

1. Quit OpenMusic and move `OpenMusic.app` to the Trash.
2. Delete `~/Library/Application Support/OpenMusic` (queue, sidebar) and `~/Library/Caches/OpenMusic` (artwork and page cache).
3. Delete its settings: `defaults delete dev.openmusic.OpenMusic` in Terminal.
4. Delete `~/Library/WebKit/dev.openmusic.OpenMusic` if it exists (the Google sign-in window's data).
5. Delete the saved sign-ins: in Keychain Access, search for `dev.openmusic.keychain` and delete the items it finds.

**iPhone:** delete the app. iOS keeps an app's Keychain items after it is deleted, so a reinstall may come back signed in. To remove them, sign out of YouTube Music, Spotify and sync in OpenMusic before deleting it.
