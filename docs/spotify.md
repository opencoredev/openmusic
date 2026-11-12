# Spotify in OpenMusic

How OpenMusic signs in to Spotify, what that depends on, how to switch to a Client ID of your own, and how Spotify playback works. Spotify is available in the Mac and iPhone apps; the Windows app doesn't have it yet.

## How sign-in works

Spotify's Web API only accepts sign-ins through a registered OAuth client, identified by a Client ID. By default OpenMusic signs in with the same public Client ID that [librespot](https://github.com/librespot-org/librespot), [ncspot](https://github.com/hrkfdn/ncspot) and [spotify_player](https://github.com/aome510/spotify-player) use: the ID of Spotify's own desktop client, `65b708073fc0480ea92a077233ca87bd`. Because Spotify registered loopback redirects for that client, you don't need to create a developer app or paste anything.

What happens when you click **Sign In**:

1. OpenMusic starts a one-shot listener on `http://127.0.0.1:8898/login` (or another free port if 8898 is busy).
2. Spotify's consent page opens: in your default browser on the Mac, in a sign-in sheet on the iPhone. It lists what OpenMusic asks for: your profile, library, follows, playlists, top items, recently played, and playback state and control.
3. After you agree, Spotify redirects to the local listener with a one-time code, and OpenMusic exchanges it for tokens using PKCE. There is no client secret.
4. The tokens are saved in the Keychain on this device. With [sync](../README.md#sync-and-privacy) on, the refresh token also syncs, end-to-end encrypted, to devices you approved.

### The risk

The Client ID isn't OpenMusic's. Spotify can block or rate-limit its use by other apps at any time, and Spotify's developer terms don't provide for third-party apps using it. If that happens, Spotify sign-in in OpenMusic fails with an error from Spotify, and existing sign-ins may stop refreshing. Your Spotify account itself isn't affected, and the fix below takes a few minutes.

## Use your own Client ID

A Client ID of your own doesn't depend on the shared one. Spotify's developer apps in development mode allow up to 5 Spotify accounts, and need the app's owner to have Spotify Premium.

1. Open the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard), sign in and click **Create app**.
2. Give it any name and description, and tick **Web API**.
3. Add the redirect URI OpenMusic shows, exactly, and save. With the default **Browser (loopback)** redirect it is `http://127.0.0.1:43827/callback`; with **In-app sheet** it is `openmusic://spotify-callback`.
4. Open the app's **Settings** in the dashboard and copy its **Client ID**.
5. In OpenMusic, open Spotify's settings (on the Mac: Settings › Services › Spotify; on the iPhone: Settings, then Spotify under Services), expand **Advanced**, turn on **Use my own Client ID**, paste the Client ID, and sign in again.
6. To let other people's Spotify accounts sign in through your app, add their email addresses under **User Management** in the dashboard.

Turning **Use my own Client ID** off goes back to the default sign-in.

### What changes with your own Client ID

Spotify removed some Web API endpoints for development-mode apps in February 2026: artist top tracks, related artists and new releases. Where the client still has them, OpenMusic uses them. With a development-mode app, OpenMusic builds an artist's top songs from a search instead, and new releases from Spotify's `tag:new` search. Radio is always built from searches.

## How Spotify playback works

OpenMusic doesn't play Spotify audio itself. It browses Spotify, keeps the queue, and sends each song, one at a time, to one of two places:

| Route | Where | Account | Notes |
| --- | --- | --- | --- |
| Spotify app on this Mac | Mac only | Free or Premium | OpenMusic controls the Spotify app through Apple Events. macOS asks once whether OpenMusic may control Spotify; allow it. |
| Spotify Connect device | Mac and iPhone | Premium | Any device with Spotify open and signed in to the same account: a phone, a computer, a speaker. The iPhone app plays Spotify only this way. |

On the Mac the route is **Automatic** by default: the Spotify app when it is installed, otherwise Spotify Connect. You can pick one in Spotify's settings.

Common messages:

- **"No active Spotify device."** Spotify Connect has nowhere to play. Open Spotify on a device signed in to the same account, start and pause any song there, then try again, or pick a device in Spotify's settings in OpenMusic.
- **"Spotify Connect playback needs Spotify Premium."** Spotify refuses Connect playback on Free accounts. On a Mac, install the Spotify app and use the **Spotify app on this Mac** route.
- **"The Spotify app isn't installed on this Mac."** The route is set to the Spotify app but it isn't installed. Install it or switch the route.

More in [Troubleshooting](troubleshooting.md#spotify).
