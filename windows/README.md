# OpenMusic for Windows

A native Windows 11 player for YouTube Music and Spotify, built with WinUI 3 (Windows App SDK 1.8) on .NET 10. It shares its logic with a cross-platform C# core, `OpenMusic.Core`, which builds and tests on Linux. It plays YouTube Music (signed out, or signed in with Google in a WebView2 window) and syncs with the Mac and iPhone apps through a OpenMusic account. `--demo` runs on the mock catalog for screenshots.

## What's here

| Project | What |
| --- | --- |
| `src/OpenMusic.Core` | `net10.0`, no Windows dependency, no packages. Models, `IMusicProvider`, `IPlaybackEngine`, `PlayerController` (a port of the Swift one), queue persistence, LRCLIB, the sync wire shapes, `MockProvider` with the demo catalog. |
| `tests/OpenMusic.Core.Tests` | xunit. PlayerController, history, durations, sleep timer, persistence, LRCLIB, wire fixtures written by the Swift encoder, mock catalog parity with Swift. |
| `src/OpenMusic.Providers.YouTube` | `net10.0`. YouTube Music over InnerTube: browse, search, library, likes, playlists, lyrics, stream resolution, Google sign-in pieces for WebView2. |
| `tests/OpenMusic.Providers.YouTube.Tests` | xunit on recorded fixtures. |
| `src/OpenMusic.Probe` | `openmusic-probe ytm …` CLI. |
| `src/OpenMusic.App` | The WinUI 3 app: unpackaged, self-contained, x64 and arm64. |

## Build and test

On Linux (or any OS with the .NET 10 SDK), the core and its tests:

```bash
~/.dotnet/dotnet test windows/OpenMusic.Core.slnf
```

`OpenMusic.sln` also holds the app, which only builds on Windows (the XAML compiler is a Windows program), so use the `.slnf` on Linux.

On Windows (the app needs the .NET 10 SDK, nothing else; no Visual Studio):

```powershell
dotnet build src\OpenMusic.App\OpenMusic.App.csproj -c Debug -p:Platform=x64
dotnet publish src\OpenMusic.App\OpenMusic.App.csproj -c Release -r win-x64 -p:Platform=x64 -o publish
dotnet publish src\OpenMusic.App\OpenMusic.App.csproj -c Release -r win-arm64 -p:Platform=ARM64 -o publish-arm64
```

The publish folder runs as is on Windows 10 2004 (build 19041) or later and Windows 11: `publish\OpenMusic.exe`. Release publishes are trimmed and ReadyToRun-compiled for a fast start, except the three biggest projection and crypto assemblies; 99.9 MB for x64 (41.5 MB zipped). See AGENTS.md "Publish size" for what was tried. `EnableMsixTooling` stays on even though the app is unpackaged: without it `dotnet publish` leaves out `OpenMusic.pri`, which holds the compiled XAML, and the window fails to load.

### From Linux, in a test VM

`scripts/windows-vm.sh` wraps a VM helper script that is not part of this repo (`OPENMUSIC_WIN_VM` in `scripts/local.env`, default `~/vms/medley-win/win.sh`). It takes `push <dir> <slot>`, `ps <powershell>`, `gui <slot> <command line>`, `kill <process>`, `shot <out.png>` and `pull <remote glob> <dir>` against a Windows 11 VM with the .NET 10 SDK and OpenSSH:

```bash
scripts/windows-vm.sh build              # push windows/ to C:\medley\win and build (Debug, x64)
scripts/windows-vm.sh publish            # Release, self-contained, to C:\medley\win\publish
scripts/windows-vm.sh run --play         # start it in the VM's desktop session
scripts/windows-vm.sh shot out.png       # screenshot the VM screen
scripts/windows-vm.sh snapshot out/      # --snapshot in the VM, PNGs copied to out/
scripts/windows-vm.sh log                # tail the app log
```

`scripts/windows-council-shots.sh <out-dir> [--no-build] [--only demo|live|narrow]` captures every main screen in the real window (light and dark, 1440x900, plus 1024x700), cropped to the window frame, for design review: demo screens, dialogs with sample data, and a live pass with a sync probe device as a second device in a `+clerk_test` account. `scripts/windows-selftest.sh launch '<args>' -- '<command>' …` runs the Debug self-test steps one by one (`snap`, `log` and any `Services/SelfTest.cs` command).

Set `OPENMUSIC_VM_SLOT` to use your own slot. The script touches pushed files after copying because the VM sees the host's mtimes as older than its build output, which made incremental builds skip changes.

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
- The demo dataset (default with `--demo`) is real chart albums with a made-up listener. Its covers come from `scripts/demo-art.sh <dir>` (Apple's artwork CDN; never committed). Put them in `%LOCALAPPDATA%\OpenMusic\demo-art`, next to `OpenMusic.exe` in `demo-art\`, or pass `--demo-art`. Without them every cover is drawn procedurally.
- Mock songs play as a generated arpeggio as long as the song (a WAV written once to `%LOCALAPPDATA%\OpenMusic\mock-audio`), so playback, the scrubber, synced lyrics, the media keys and the Windows media flyout all work with no network. `--mock-audio-url` plays a URL instead.
- The queue is saved to `%LOCALAPPDATA%\OpenMusic\queue.json` (the Swift app's format) and restored paused at launch.
- The log is `%LOCALAPPDATA%\OpenMusic\logs\openmusic.log`: launches, player state changes, errors, and the position every 5 s while playing.

Keyboard shortcuts are one list (`Services/Shortcuts.cs`), shown in Help › Keyboard Shortcuts (Ctrl+/ or F1): Space or Ctrl+P play/pause, Ctrl+Left/Right previous/next, Ctrl+Up/Down volume, Ctrl+S shuffle, Ctrl+R repeat, Ctrl+F search, Ctrl+L lyrics, Ctrl+U Up Next, Ctrl+N Now Playing, Ctrl+M mini player, Ctrl+D devices, Alt+Left back, Ctrl+1/2/3 Home/New/Radio, Ctrl+, Settings, Esc closes Now Playing.

### Snapshots

`OpenMusic.exe --snapshot <dir>` opens each main screen in the real window at 1440x900, in light and dark, writes `light-home.png`, `dark-album.png`, … plus `light-mini.png`/`dark-mini.png` (the mini player at 320x320), logs each file, and exits (exit code 1 if anything failed). Screens: home, new, album, artist, playlist, search, songs, albums, lyrics, queue, nowplaying, settings. The window is rendered with `RenderTargetBitmap` over Mica Alt's base color, since that API can't see the backdrop; for pixel-exact screenshots with Mica and the title bar, take a VM screenshot of the running window (`scripts/windows-vm.sh shot`).

## The test VM

Notes from setting up the QEMU test VM:

- The VM had no audio device, so MediaPlayer failed every source with `SourceNotSupported`. The VM's launch script now gives QEMU a virtual Intel HDA card with a `none` backend (output discarded): Windows gets a "Speakers" endpoint and playback runs. Listen-free verification: the log's position lines advance.
- On first launch the app registers its AppUserModelID and a Start menu shortcut (`%APPDATA%\Microsoft\Windows\Start Menu\Programs\OpenMusic.lnk`) so the media flyout says "OpenMusic", not "Unknown app".
- `win.sh gui` takes the command line unquoted: `win.sh gui win 'C:\path\OpenMusic.exe --play'`. Quoting the path inside breaks the scheduled task's command.
