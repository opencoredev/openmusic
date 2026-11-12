# OpenMusic for Windows: agent guide

Read the root [AGENTS.md](../AGENTS.md) first (goals, rules, sync). This folder is the Windows app and the C# core. Build, run and snapshot commands are in [README.md](README.md).

Goals, in order: feels native (a first-party Windows 11 app, not a Mac port), fast (instant UI, no spinners for cached content), light (small, zero idle CPU while paused), full feature coverage of both services.

## Layout and ownership

| Path | What | Owner |
| --- | --- | --- |
| `OpenMusic.sln`, `Directory.Build.props`, `OpenMusic.Core.slnf` | Solution, shared build settings, the Linux-buildable subset. | coordinator |
| `src/OpenMusic.Core/Contracts/` | Models, `IMusicProvider`, `IPlaybackEngine`, capabilities, errors. The shared contract, mirroring `Sources/OpenMusicCore/Contracts/`. | coordinator (additive changes OK, report them) |
| `src/OpenMusic.Core/Playback/` | `PlayerController`, `KnownLengths`, `QueueStore`/`QueuePersistence`, scheduler. A port of the Swift player; keep the semantics identical (see "Porting rules"). | playback worker |
| `src/OpenMusic.Core/Support/` | JSON (`OpenMusicJson`, Swift-compatible), `LrcLibClient`, `UndoStack`. | coordinator (additive OK) |
| `src/OpenMusic.Core/Sync/Wire.cs` | The sync backend's shapes (anchor, queue window, commands, settings keys). | sync worker |
| `src/OpenMusic.Core/Mock/` | `MockProvider`, the sample and demo catalogs, procedural artwork. | UI worker |
| `src/OpenMusic.Core/Threading/` | `MainThreadContext`, the main actor for tests and console tools. | coordinator |
| `src/OpenMusic.Providers.YouTube/` | `YouTubeMusicProvider`: InnerTube, sign-in, stream resolution (`IStreamResolver`). `net10.0`, no Windows dependency, so it tests on Linux. See its README. | YouTube worker |
| `src/OpenMusic.Probe/` | `openmusic-probe ytm …`: the provider from a terminal (Linux too). | YouTube worker |
| `src/OpenMusic.Providers.Spotify/` (later) | `SpotifyProvider`. | Spotify worker |
| `src/OpenMusic.Sync/` | Convex WebSocket client, Clerk sign-in, `SyncService`, `SyncCoordinator`, sign-in vault, settings sync. `net10.0`. Port of `Sources/OpenMusicSync/` against `docs/sync-design.md`. See its README. | sync worker |
| `src/OpenMusic.SyncProbe/`, `tests/OpenMusic.Sync.Tests/`, `scripts/live-*.sh` | A fake sync device for live tests; unit, race and Swift-vector tests. | sync worker |
| `src/OpenMusic.App/Pages/` | One page per screen (Home/New, Radio, Album, Artist, Playlist, Search, Songs, Library grids, Devices, Settings). | UI worker |
| `src/OpenMusic.App/Controls/` | Shell pieces: now-playing bar, side pane (Lyrics/Up Next), Now Playing, mini player, `ShelfView`, `TrackList`, `ArtworkView`, `LyricsView`. | UI worker |
| `src/OpenMusic.App/ViewModels/` | `PlayerViewModel` (shared), one view model per page, row and card items. | UI worker |
| `src/OpenMusic.App/Styles/` | `Theme.xaml` (sizes, brushes, text and button styles), `Converters`. | UI worker |
| `src/OpenMusic.App/Services/` | `AppServices` (composition root), `MediaPlaybackEngine` with `HttpRangeStream` and `RemuxedStream`, `SyncHub`, `Dpapi`, `AppSettings`, `MediaMenus` (right-click menus), `Shortcuts` and `Dialogs`, `SystemMediaControls`, `ArtworkLoader`, `MockAudioResolver`, `Snapshotter`, `SelfTest` (Debug), `Log`. | coordinator; providers register here |
| `src/OpenMusic.App/Interop/` | Win32: taskbar thumbnail buttons, window subclass. | coordinator |
| `src/OpenMusic.App/ShellPage.xaml`, `MainWindow.cs`, `MiniPlayerWindow.cs`, `YouTubeSignInWindow.cs`, `Program.cs` | The shell, its InfoBars and account menu; the windows; the WebView2 sign-in; the single-instance entry point. | UI worker (coordinate shell changes) |
| `tests/OpenMusic.Providers.YouTube.Tests/` | xunit on Swift-recorded and live fixtures. | YouTube worker |
| `tests/OpenMusic.Core.Tests/` | xunit; `Fixtures/` are written by `scripts/windows-fixtures/generate.sh`. | per area owner |
| `../scripts/windows-*.{sh,py}` | VM helper, fixture generator, icon generator. | coordinator |

## What each worker builds against

- **Providers** implement `IMusicProvider` (Contracts/IMusicProvider.cs). Network and parsing off the UI thread (`ConfigureAwait(false)`), results returned to the awaiting caller on the UI thread, `PropertyChanged` for `AuthStatus` raised on the UI thread. Unsupported calls throw `ProviderException.NotSupported(...)` and `Capabilities` says what works. For playback, implement `IStreamResolver` and give the provider a `MediaPlaybackEngine(resolver, dispatcher)` (in the app, or inject `IPlaybackEngine` into the provider's constructor as `MockProvider` does). Streams needing headers (YouTube) will need `MediaSource.CreateFromStream` over an HTTP stream; extend `MediaPlaybackEngine` for that. Sign-in UI (WebView2 for Google is allowed) lives in the app: add a `Pages/SignIn` page or dialog per provider; the core has no UI types. Use `LrcLibClient` as the lyrics fallback.
- **Sync** builds `OpenMusic.Sync` on `PlayerController` (`Load(entries, index, position, shuffle, repeat, autoplay)` for handoff, `Snapshot()`, `AddChangeHandler`) and the wire types in `OpenMusic.Core.Sync`. All JSON goes through `OpenMusicJson.Serialize(value, OpenMusicJsonContext.Default.X)`, which writes what Swift's JSONEncoder writes; settings values through `OpenMusicJson.EncodeSetting` (compared as text by the Swift `SettingsSync`). The backend's `platformV` only accepts `mac` and `ios`: add `windows` in `sync/convex/model.ts` before a PC can pair (`DevicePlatform.Windows` exists on the C# side). Secrets: DPAPI (`ProtectedData`, CurrentUser) or Windows Credential Locker, never files in plain text.
- **UI** deepens the pages. Every screen is a `Page` with its own view model; shared look goes in `Styles/Theme.xaml`; long lists stay virtualized (`TrackList` with a `Header` is the page's scroller). Navigation goes through `ShellPage.Current.Navigate(tag, parameter)` and `Open(MediaItem)`. Artwork goes through `ArtworkView` (cached, decoded at display size). Check every change with `--snapshot` in light and dark, at 1440 and at 800 px wide (`--size 800x700`).

## Porting rules

- The C# core mirrors the Swift sources file for file. When the Swift `PlayerController` changes, port the change and its tests; behavior must stay the same on both platforms (the sync handoff depends on it).
- `PlayerController` is single-threaded like Swift's main actor: drive it from the UI thread (or `MainThreadContext.Run` in tests and tools). Loads and radio fetches start on a later turn (`Task.Yield`), as Swift's `Task { }` does; tests depend on that ordering.
- Wire types: no `[JsonPropertyName]` drift, nil optionals omitted, UUIDs uppercase, URLs as strings, `Date` as seconds since 2001. After changing a Swift model, rerun `scripts/windows-fixtures/generate.sh` (Linux `swiftc`) and fix the C# side until `WireFormatTests` pass. The same script regenerates `DemoCatalogData.json` from the Swift demo catalog; `MockCatalogParityTests` check the C# catalogs against Swift bit for bit.
- Types that XAML sees must have a public parameterless constructor without `required` members (the XAML compiler generates `new T()`); keep such properties `internal` or wrap them, as `TrackList.Context` does.

## Live app notes

- Playback: YouTube's direct audio (itag 140) is a DASH fragmented MP4, which Media Foundation ends at once. `MediaPlaybackEngine` plays its flat view (`OpenMusic.Providers.YouTube/Playback/FragmentedMp4`, `Services/RemuxedStream`): the sidx and every fragment's moof are read first (about 100 to 200 ms), the audio itself streams through `HttpRangeStream`, which sends the stream's headers and asks for 4 MB ranges. Media Foundation clones the byte stream it's given, so `HttpRandomAccessStream` implements `IRandomAccessStream` itself (.NET's `AsRandomAccessStream` can't clone). HLS through `AdaptiveMediaSource` never opened in the VM; Settings keeps the stream format choice, Direct is the default.
- A network stream reports a short Paused right after its first Buffering; the engine counts a pause from outside only after 600 ms.
- Threading: `SyncHub`'s `SyncActor` is the UI thread's context, so OpenMusic.Sync, the player and the YouTube provider's property changes all arrive on the UI thread. The provider's account work runs on its own executor and resumes awaiting callers there. Sync starts through `AccountService.StartSyncAsync`.
- Secrets: `Services/Dpapi.cs` (CryptProtectData, CurrentUser, with the app's own entropy, still the pre-rename string, which must stay so secrets saved by earlier builds still open) seals the YouTube sign-in (`ytm.credentials`, `ytm.account`), the transfer snapshot and every OpenMusic.Sync secret, one file each in `%LOCALAPPDATA%\OpenMusic\secrets`. Convex validation errors echo the request below the error (device token included): `OpenMusic.Sync`'s `ServerText.Clean` drops the echo and redacts secret-looking values wherever server text enters an exception (`ConvexClientException`, `SyncException`, auth and fatal errors), and `Log` and the InfoBars still run text through `Log.Redact`.
- `openmusic:` is registered per user in HKCU at each live launch (`Software\Classes\openmusic`); the process's AppUserModelID is `OpenMusic`, with a Start menu shortcut `OpenMusic.lnk` carrying it, and the single-instance key is `OpenMusic.Main`; `Program.cs` keeps one instance and hands a second launch or a link to the running one (Google sign-in through the browser comes back this way).

## Publish size

99.9 MB self-contained x64 (41.5 MB as a zip), from 182.6 MB: Release publishes are trimmed (`TrimMode=partial`, so the framework, the Windows and WinUI projections and the trimmable libraries; the app and OpenMusic.Sync keep everything, with built-in COM and reflection JSON on). ReadyToRun leaves out the Windows SDK projection, WinUI's projection and BouncyCastle (mostly projections OpenMusic calls a little of), and the publish drops the Windows AI and ML components, Widgets, Workloads, the PDB reader and PDBs, none of which OpenMusic activates. Launch to window: about 0.7 s warm in the VM.

Checked in the VM on a trimmed build: every screen draws, live playback advances, the media flyout shows the song, art and an advancing timeline, the taskbar and app identity work, and (on a trimmed Debug publish, `dotnet publish -c Debug -p:PublishTrimmed=true`, which uses the dev deployment and keeps the self-test) OpenMusic sign-out and email-code sign-in, the key exchange with a second device, Play Here and the YouTube sign-in window. Release builds point at the production deployment (`SyncService.ProductionDeploymentUrl`), Debug builds at dev (`DefaultDeploymentUrl`); `OPENMUSIC_SYNC_URL` overrides both.

Why trimming once broke playback: `YouTubeStreamResolver.ResolveAsync` started its lookup inside its `lock`, and the lookup's first step posted to the UI thread's synchronization context while the lock was held. In a trimmed build the lock was left held by a thread that had exited (a dump showed the UI thread waiting in `Lock.EnterScope` from `PrepareNext`, owner thread gone), so the UI thread blocked as playback started: Media Foundation kept reading and the audio played, but no tick or player event ran again. The lookup now starts outside the lock, on the thread pool. When a trimmed build misbehaves: `OPENMUSIC_TRACE_EXCEPTIONS=1` logs every first-chance exception, and `dotnet-dump collect` / `analyze -c "clrstack -all"` in the VM shows where the UI thread waits.

Tried and not used:
- Single file with compression (96 MB): eight seconds to unpack at launch, then no window.

## Known gaps

- Memory, live Home in the VM (Debug, `--self-test` `memory` after `scroll all`): about 290 MB working set (140 MB private) at launch, 310 MB (155 MB private) after scrolling every shelf, 380 MB (220 MB private) after New as well. The floor is the shell: Settings alone is 213 MB working set (77 MB private), of which about 110 MB are DLL pages shared with other processes and much of the rest is WARP (the VM has no GPU, so every surface is in system memory). Art is decoded at the size shown and its caches are bounded (12 MB decoded, 8 MB of files); a 172 px card still costs several times its pixels in WARP. `OPENMUSIC_NO_ART=1` (Debug) leaves art out, for comparisons.
- Mica Alt is set; in the VM (no GPU) Windows draws its fallback color.
- Crossfade and Sound Check are accepted by `MediaPlaybackEngine` but not applied yet.
- Playback, queues, takeovers and settings are sealed with the vault key (merged from `work/win-sync-sealed`). A PC that isn't approved yet sees that another device plays and where, not the song ("Playing on Riley's Mac · 2:13"), and Play Here tells it to get approved first.
- Flyout and menu items can't be found by the VM's UI Automation script; the Debug self-test's `click <AutomationId>` presses them through their automation peer.

## Rules

- No Electron, no web views for UI (WebView2 only for Google sign-in). Packages: CommunityToolkit.Mvvm and CommunityToolkit.WinUI controls are fine; ask before adding anything else. The core takes no packages.
- Zero idle CPU: no timers while paused (the engine's 250 ms ticker runs only while playing), no polling.
- Never log tokens, cookies or account data (`Services/Log.cs` writes a plain file).
- Verify in the VM, not just by building: run the app, take a screenshot, read the log. Leave nothing running when you finish (`scripts/windows-vm.sh kill`).
