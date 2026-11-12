# OpenMusic for iPhone

SwiftUI app for iOS 26 and later. It links `OpenMusicCore`, `YouTubeMusicKit`, `SpotifyKit` and `OpenMusicSync` from the local package. `project.yml` is the XcodeGen spec. The generated `OpenMusic.xcodeproj` is gitignored.

## Build and run

Builds run on the build Mac (`OPENMUSIC_MAC_HOST` in `scripts/local.env`, see AGENTS.md) in a simulator owned by your slot (`agent-openmusic-<slot>`, created on first use, addressed by UDID):

```bash
scripts/ios.sh <slot> build                                   # xcodegen + xcodebuild
scripts/ios.sh <slot> run                                     # build, install, launch (live YouTube Music)
scripts/ios.sh <slot> run -OpenMusicMock YES -OpenMusicScreen album # sample data, opens one screen
scripts/ios.sh <slot> snapshots                               # every screen, light and dark, into build/shots/
scripts/ios.sh <slot> selftest                                # live check: home, search, album, play, next, lyrics,
                                                              # Now Playing info, audio session, backgrounding
scripts/ios.sh <slot> delete                                  # delete the slot's simulator
rsync -az "$OPENMUSIC_MAC_HOST:agents/openmusic-<slot>/build/shots/" <dir>/
```

Launch arguments: `-OpenMusicMock YES` (sample data), `-OpenMusicSignedOut YES` (with mock), `-OpenMusicScreen <name>` (see `App/SnapshotDriver.swift`), `-OpenMusicSelfTest live`, `-OpenMusicSyncDeviceName "<name>"`. Debug builds only, read from the command line and never from saved defaults: `-OpenMusicSyncSelfTest YES` (sync log, `openmusic://test/…` commands and the probe's fake test sign-ins, see `Sync/SyncSelfTest.swift`) and `-OpenMusicOpenURL <link>` (opens a `openmusic://` link at once, during launch). Release builds compile none of this. `OPENMUSIC_CONFIG=Release scripts/ios.sh <slot> build` builds Release.

Live sync check against a `openmusic-probe sync` device, with screenshots of every sync screen in light and dark:

```bash
scripts/ios.sh <slot> build
scripts/mac.sh <slot> 'scripts/ios-sync-live.sh'   # logs in build/sync-live/, shots in build/shots/sync-*.png
```

Simulator builds are ad-hoc signed. To run on your own iPhone, run `xcodegen generate --spec iOS/project.yml`, open the generated `iOS/OpenMusic.xcodeproj` in Xcode, turn on Automatically manage signing for the `OpenMusic` target and pick your Apple ID's team (and change the bundle id if Xcode asks for a unique one), and run on the device. The project is set to manual ad-hoc signing so command-line simulator builds need no team. `scripts/install-iphone.sh` does the same from the command line with a profile you already have (see AGENTS.md, "iOS and sync").

## Layout

| Path | What |
| --- | --- |
| `OpenMusic/App/AppModel.swift` | The app model: providers, the one `PlayerController`, `PlaybackSystem`, navigation per tab, library and search state, `AppExtensions`. |
| `OpenMusic/App/RootView.swift` | `@main`, the `TabView` (Home, New, Library, Search), mini player accessory, Now Playing cover, sheets, toasts. |
| `OpenMusic/App/SnapshotDriver.swift` | Screenshot mode and the live self-test. |
| `OpenMusic/Design/` | Artwork pipeline, shared rows, cards, menus and the `Loader` (loading, error, retry, pull to refresh). |
| `OpenMusic/Pages/` | Home, New, See All, album, artist, playlist, search, library. |
| `OpenMusic/Player/` | Mini player, Now Playing (scrubber, transport, volume, AirPlay), lyrics, queue. |
| `OpenMusic/Settings/` | Accounts and playback settings. |
| `OpenMusic/Sync/` | OpenMusic Sync: `SyncHub` (service, coordinator, sign-in transfers, settings), Settings › Sync, account sign-in and device approval, the Devices sheet and the "Continue from" banner. |

## Sync

`AppModel.launch()` creates `SyncHub` after the providers restored their sessions (not with `-OpenMusicMock`). Sync is an OpenMusic account: sign in with an email code or Continue with Apple or Google (Clerk's web sign-in in a browser sheet, back through `openmusic://oauth-callback`), from the first-run flow or Settings › Sync (`OpenMusic/Sync/AccountViews.swift`). The sync socket opens only once the account is signed in. The first device of an account creates the library key; a later device waits for approval on a device that has it, after both show the same six-digit code, and until then a quiet banner stays on Home. `SyncHub` starts `SyncCoordinator` on the one player, registers `YouTubeMusicSignInTransfer` and `SpotifySignInTransfer` (a Spotify refresh that Spotify refuses first looks for the token another device rotated), binds `PlaybackSettings` and recent searches, and passes scene-phase changes to `setForeground`, which also retries a sign-in or registration that failed while offline. YouTube Music counts as playable signed out (`coordinator.canPlay`). The Devices sheet (`OpenMusic/Sync/DevicesViews.swift`) opens from Now Playing: tap a device to send what's playing to it, control one that's playing, or take its music with Play on This iPhone. The "Continue from …" banner above the mini player continues another device's music here in one tap.

The hooks it plugs into, without editing the core screens:

- `model.player` is the one `PlayerController`. Attach `SyncCoordinator` to it.
- `model.extensions.miniPlayerBanner` (an `AnyView?`) shows just above the mini player on every tab, for example the "Continue from Mac" banner.
- `model.extensions.nowPlayingAccessory` (an `AnyView?`) shows in Now Playing's bottom bar between AirPlay and the queue button, for example a Devices button.
- `model.extensions.urlHandlers` get `openmusic://` links first (for example `openmusic://oauth-callback`). Return true to claim one.
- `AppModel.syncURL` reads `OpenMusicSyncURL` from Info.plist. It defaults to the dev deployment and is set per build with the `OPENMUSIC_SYNC_URL` build setting.

`OpenMusic/Sync/SyncHub.swift` fills these.

## System integration

- `AVAudioSession` uses the `.playback` category with `longFormAudio` routing. It is activated when playback starts, so launching OpenMusic doesn't stop other apps' audio. Calls and Siri pause playback, and it resumes when iOS allows. Unplugging headphones or losing AirPods pauses (`OpenMusicCore/System/AudioSession.swift`, `AudioOutputMonitor`).
- Now Playing info and remote commands come from `OpenMusicCore.NowPlayingCenter`: lock screen, Control Center, AirPods and the Love command.
- The queue is saved on every change and when the app goes to the background, then restored paused at launch.
- Volume is the system volume (`MPVolumeView`). The player itself stays at full volume.
