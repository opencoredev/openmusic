# OpenMusic

OpenMusic (formerly Medley) is a music player for YouTube Music and Spotify on Mac, iPhone and Windows. YouTube Music works on all three. Spotify works on Mac and iPhone; Spotify on Windows is coming.

Each app is written for its platform: SwiftUI on the Mac and iPhone, WinUI 3 on Windows. The Apple apps have no third-party dependencies.

## What it does

- Home, New (new releases, moods and genres, charts), search with live suggestions and scopes, album, artist and playlist pages.
- Your library when signed in: liked songs, songs, albums, artists, playlists, recently played. Like, save, follow, create and edit playlists.
- A real queue: Play Next, Add to Queue, drag to reorder, shuffle, repeat, autoplay radio when the queue runs out, sleep timer.
- Synced lyrics in a side panel and in the full-screen player. YouTube Music's own lyrics come first, then LRCLIB.
- System media controls: media keys, Control Center, the lock screen, AirPods, the Windows media flyout.
- Mini player, keyboard shortcuts, light and dark mode.
- Handoff between devices: pick up on your iPhone what your Mac was playing, send playback to another device, or control it from here.
- Sync of settings, recent searches and service sign-ins across your devices, end-to-end encrypted. The sync server sees when you play and pause, never what you play.
- Sync is optional, and you can run your own sync server.

## Install

### Mac

Download OpenMusic for macOS from [Releases](https://github.com/opencoredev/openmusic/releases), open it and move OpenMusic to Applications. The Mac builds attached to releases are signed with a Developer ID and notarized by Apple, so macOS opens them without a warning; that signing happens outside this repository's scripts. A release without a Mac build means the signed build isn't ready yet: build it from source meanwhile. Needs macOS 15 or later on an Apple silicon Mac.

### Windows

Download the x64 zip from [Releases](https://github.com/opencoredev/openmusic/releases), extract it anywhere and run `OpenMusic.exe` in the `OpenMusic` folder it makes. The folder also holds `LICENSE` and `THIRD-PARTY-NOTICES.txt`, the licenses of the components it bundles. Needs Windows 10 version 2004 or later, or Windows 11. Nothing else to install.

The Windows build isn't code-signed, so SmartScreen warns the first time you run it ("Windows protected your PC"). Click **More info**, then **Run anyway**. If Windows blocks the files before that, right-click the zip before extracting it, choose **Properties**, tick **Unblock** and click **OK**.

### iPhone

There is no App Store build. Two ways to get it on your iPhone (iOS 26 or later):

- **Build it with Xcode.** On a Mac with Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), run `xcodegen generate --spec iOS/project.yml` in this repository, open `iOS/OpenMusic.xcodeproj`, under **Signing & Capabilities** for the `OpenMusic` target turn on **Automatically manage signing** and choose your Apple ID's team (change the bundle identifier if Xcode says it is taken), connect your iPhone and press Run. A free Apple ID works; apps signed with one stop opening after 7 days until you run them from Xcode again.
- **Sideload it with [AltStore](https://altstore.io) or [SideStore](https://sidestore.io).** They sign an `.ipa` with your own Apple ID and refresh it before it expires. Releases don't include an `.ipa` yet, so build one yourself from the Xcode project.

## Signing in

**YouTube Music:** Settings › Accounts › YouTube Music › Sign In, then sign in with Google in the window that opens. If Google refuses the embedded window, use "Sign in with a browser cookie (advanced)": in Safari or Chrome open music.youtube.com, open the developer tools' Network tab, copy the `Cookie` request header from any request to `music.youtube.com`, and paste it. Everything except your library works signed out, including playback.

**Spotify** (Mac and iPhone): click Sign In, log in to Spotify in your browser, and you're back in OpenMusic, signed in. There's no developer app to create and no Client ID to paste. To play songs, install the Spotify app on the Mac (OpenMusic controls it; allow it when macOS asks), or have Spotify open on any device with Premium (Spotify Connect).

How Spotify sign-in works: OpenMusic signs in with Spotify's own desktop client ID (`65b708073fc0480ea92a077233ca87bd`), the one librespot, ncspot and spotify_player log in with, through OAuth PKCE and a one-shot listener on `http://127.0.0.1:8898/login` (any free port if 8898 is busy). Spotify's developer terms don't allow borrowing it, and Spotify could rate-limit or block it at any time. If that happens, open Settings › Accounts › Spotify › Advanced, turn on **Use my own Client ID**, and follow the steps there: create an app at developer.spotify.com/dashboard, tick **Web API**, add the redirect URI `http://127.0.0.1:43827/callback`, and paste the Client ID. Development-mode apps allow at most 5 users and need the app's owner to have Premium.

Where the client still has them, OpenMusic uses artist top tracks, related artists and new releases. Where Spotify has removed them (development-mode apps since February 2026), it builds top songs from an artist search and new releases from the `tag:new` search. Radio is always built from searches.

## Sync and privacy

Sign in with an OpenMusic account on each device (Mac, iPhone, Windows) to pick up what another device plays, send playback to it or control it, and keep your settings, recent searches and service sign-ins the same everywhere. A new device gets your encryption key only after you approve it on a device that already has it, by comparing a six-digit code.

What you play, your queue, your searches, your settings and your sign-ins are encrypted on your devices with a key the server never has. The server sees which devices you have and when they play, pause or seek, never what. [What the server can see](docs/sync-design.md#what-the-server-can-see) lists every field it stores. OpenMusic works without an account; sync is optional.

## Run your own server

The sync server is the open-source Convex backend in `sync/convex/`, with sign-in through a Clerk app you control. Run it on any Linux or macOS machine with Docker or Podman, give it an HTTPS address (Tailscale Serve or a reverse proxy), and enter that address in OpenMusic's sign-in screen under **Use your own server**. [Running your own OpenMusic server](docs/self-hosting.md) has the steps.

## Build from source

- Mac: on a Mac with Xcode 27, `swift build`, `swift test`, and `scripts/bundle.sh` for `build/OpenMusic.app`. `OPENMUSIC_MOCK=1` runs the app on sample data with no network.
- iPhone: [iOS/README.md](iOS/README.md).
- Windows: [windows/README.md](windows/README.md). The shared C# core builds and tests on Linux too: `dotnet test windows/OpenMusic.Core.slnf`.
- Sync backend: `sync/` (`npm ci`, then `npx vitest run`).

[AGENTS.md](AGENTS.md) covers the architecture, the rules every change follows, signing and the Keychain, and the test and screenshot scripts. If your checkout lives on Linux, the scripts run Apple builds on a Mac over SSH: copy `scripts/local.env.example` to `scripts/local.env` and fill it in.

## Limits

- YouTube Music streams are AAC at about 128 kbps. Premium's 256 kbps needs signature deciphering, which OpenMusic does not do.
- YouTube playback uses the visionOS InnerTube client, the one client that currently returns playable audio without a PO token. If YouTube changes that, playback stops until the client list is updated (`Sources/YouTubeMusicKit/Playback/YouTubeStreamResolver.swift`).
- Mac builds attached to releases are signed with a Developer ID and notarized. Builds you make yourself (`scripts/bundle.sh`) are signed with a local self-signed certificate (see AGENTS.md), or ad-hoc without one; an ad-hoc build starts signed out of YouTube Music and Spotify every time.
- The Windows app plays YouTube Music only for now, and isn't code-signed. Releases are x64; ARM64 builds from source (`-p:Platform=ARM64`).

## Disclaimer

OpenMusic is an unofficial app. It is not affiliated with, endorsed by or sponsored by Google, YouTube or Spotify. It uses unofficial interfaces to those services, which can change or stop working at any time. OpenMusic streams music for playback only; it never downloads or saves music. YouTube, YouTube Music and Spotify are trademarks of their owners, and other product names belong to their owners. You are responsible for following the terms of service of YouTube, Spotify and any other service you use with OpenMusic.

## Licence

MIT. See [LICENSE](LICENSE).
