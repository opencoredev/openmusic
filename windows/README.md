# OpenMusic for Windows

A native YouTube Music player for Windows 10 (2004 or later) and Windows 11, built with WinUI 3 (Windows App SDK 1.8) on .NET 10. It plays YouTube Music signed out, or signed in with Google in a WebView2 window, and syncs with the Mac and iPhone apps through an OpenMusic account. Spotify isn't in the Windows app yet. It shares its logic with a cross-platform C# core, `OpenMusic.Core`, which builds and tests on Linux. `--demo` runs on the mock catalog for screenshots.

## What's here

| Project | What |
| --- | --- |
| `src/OpenMusic.Core` | `net10.0`, no Windows dependency, no packages. Models, `IMusicProvider`, `IPlaybackEngine`, `PlayerController` (a port of the Swift one), queue persistence, LRCLIB, the sync wire shapes, `MockProvider` with the demo catalog. |
| `tests/OpenMusic.Core.Tests` | xunit. PlayerController, history, durations, sleep timer, persistence, LRCLIB, wire fixtures written by the Swift encoder, mock catalog parity with Swift. |
| `src/OpenMusic.Providers.YouTube` | `net10.0`. YouTube Music over InnerTube: browse, search, library, likes, playlists, lyrics, stream resolution, Google sign-in pieces for WebView2. |
| `tests/OpenMusic.Providers.YouTube.Tests` | xunit on recorded fixtures. |
| `src/OpenMusic.Probe` | `openmusic-probe ytm …` CLI. |
| `src/OpenMusic.Sync` | `net10.0`. The sync client: Convex WebSocket client, Clerk sign-in, `SyncService`, `SyncCoordinator`, sign-in vault, settings sync. A port of `Sources/OpenMusicSync/` ([docs/sync-design.md](../docs/sync-design.md)). |
| `src/OpenMusic.SyncProbe` | A fake sync device for live tests. |
| `tests/OpenMusic.Sync.Tests` | xunit: protocol, races, sealing, and test vectors shared with the Swift client. |
| `src/OpenMusic.App` | The WinUI 3 app: unpackaged, self-contained, x64 and arm64. |

## Build and test

On any OS with the .NET 10 SDK (Linux and macOS included), the core, the YouTube provider, the sync client and their tests, from the repository root:

```bash
dotnet test windows/OpenMusic.Core.slnf
```

`OpenMusic.sln` also holds the app, which only builds on Windows (the XAML compiler is a Windows program), so use the `.slnf` on Linux.

On Windows, from the `windows` folder (the app needs the .NET 10 SDK, nothing else: the Windows App SDK comes from NuGet and is bundled, and Visual Studio isn't needed):

```powershell
dotnet build src\OpenMusic.App\OpenMusic.App.csproj -c Debug -p:Platform=x64
dotnet publish src\OpenMusic.App\OpenMusic.App.csproj -c Release -r win-x64 -p:Platform=x64 -o publish
dotnet publish src\OpenMusic.App\OpenMusic.App.csproj -c Release -r win-arm64 -p:Platform=ARM64 -o publish-arm64
```

The publish folder runs as is on Windows 10 2004 (build 19041) or later and Windows 11: `publish\OpenMusic.exe`. Release publishes are trimmed and ReadyToRun-compiled for a fast start, except the three biggest projection and crypto assemblies; 99.9 MB for x64 (41.5 MB zipped). See AGENTS.md "Publish size" for what was tried. `EnableMsixTooling` stays on even though the app is unpackaged: without it `dotnet publish` leaves out `OpenMusic.pri`, which holds the compiled XAML, and the window fails to load.

The maintainers build and package the app from Linux in a Windows VM (`scripts/windows-vm.sh`, `scripts/package-windows.sh`): [docs/maintainers.md](../docs/maintainers.md#windows-vm). Release zips extract to one `OpenMusic/` folder holding the publish, `LICENSE` and `THIRD-PARTY-NOTICES.txt`.

## Run

```text
OpenMusic.exe [--demo [--demo-sync]] [--test-sign-ins] [--self-test <file>] [--device-name <name>]
           [--screen album:<id>|artist:<id>|playlist:<id>|search:<query>| home|new|radio|album|artist|playlist|search|songs|albums|artists|liked|recent|nowplaying|devices|settings]
           [--pane lyrics|queue] [--mini] [--play] [--position <seconds>] [--theme light|dark] [--size 1280x800]
           [--dataset demo|sample] [--demo-art <dir>] [--mock-audio-url <url>] [--no-restore]
           [--snapshot <dir>]
```

- Without `--demo` (and outside `--snapshot`) the app is live: YouTube Music, its sign-in sealed with DPAPI in `%LOCALAPPDATA%\OpenMusic\secrets`, Home and New cached per account in `%LOCALAPPDATA%\OpenMusic\cache\browse`, OpenMusic Sync against the dev deployment in Debug builds and production in Release (`OPENMUSIC_SYNC_URL` overrides). `--demo-sync` adds made-up devices to the Devices flyout and a Continue InfoBar, for screenshots.
- Debug builds only: `--test-sign-ins` accepts the sync probe's fake YouTube sign-ins (`openmusic-sync-probe` step `signin-ytm`); `--self-test <file>` runs commands appended to the file (`screen`, `theme`, `pane`, `nowplaying`, `mini`, `devices`, `menu track`, `play-search q | title`, `state`, `memory`, …; see `Services/SelfTest.cs`). `scripts/windows-uia.ps1` clicks and types by AutomationId in the VM's desktop session.
- `--dataset sample` is the invented catalog with procedural covers; use it for anything published. The demo dataset (default with `--demo`) is real chart albums with a made-up listener. Its covers come from `scripts/demo-art.sh <dir>` (Apple's artwork CDN; never committed). Put them in `%LOCALAPPDATA%\OpenMusic\demo-art`, next to `OpenMusic.exe` in `demo-art\`, or pass `--demo-art`. Without them every cover is drawn procedurally.
- Mock songs play as a generated arpeggio as long as the song (a WAV written once to `%LOCALAPPDATA%\OpenMusic\mock-audio`), so playback, the scrubber, synced lyrics, the media keys and the Windows media flyout all work with no network. `--mock-audio-url` plays a URL instead.
- The queue is saved to `%LOCALAPPDATA%\OpenMusic\queue.json` (the Swift app's format) and restored paused at launch.
- The log is `%LOCALAPPDATA%\OpenMusic\logs\openmusic.log`: launches, player state changes, errors, and the position every 5 s while playing.

Keyboard shortcuts are one list (`Services/Shortcuts.cs`), shown in Help › Keyboard Shortcuts (Ctrl+/ or F1): Space or Ctrl+P play/pause, Ctrl+Left/Right previous/next, Ctrl+Up/Down volume, Ctrl+S shuffle, Ctrl+R repeat, Ctrl+F search, Ctrl+L lyrics, Ctrl+U Up Next, Ctrl+N Now Playing, Ctrl+M mini player, Ctrl+D devices, Alt+Left back, Ctrl+1/2/3 Home/New/Radio, Ctrl+, Settings, Esc closes Now Playing.

### Snapshots

`OpenMusic.exe --snapshot <dir>` opens each main screen in the real window at 1440x900, in light and dark, writes `light-home.png`, `dark-album.png`, … plus `light-mini.png`/`dark-mini.png` (the mini player at 320x320), logs each file, and exits (exit code 1 if anything failed). Screens: home, new, album, artist, playlist, search, songs, albums, lyrics, queue, nowplaying, settings. The window is rendered with `RenderTargetBitmap` over Mica Alt's base color, since that API can't see the backdrop; for pixel-exact screenshots with Mica and the title bar, take a VM screenshot of the running window (`scripts/windows-vm.sh shot`).

On first launch the app registers its AppUserModelID and a Start menu shortcut (`%APPDATA%\Microsoft\Windows\Start Menu\Programs\OpenMusic.lnk`) so the media flyout says "OpenMusic", not "Unknown app", and registers the `openmusic:` link handler in `HKEY_CURRENT_USER\Software\Classes\openmusic`. [Troubleshooting](../docs/troubleshooting.md#uninstalling) lists everything to remove when uninstalling.
