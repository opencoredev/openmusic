# OpenMusic for iPhone

OpenMusic's iPhone app: SwiftUI, iOS 26 and later. It links `OpenMusicCore`, `YouTubeMusicKit`, `SpotifyKit` and `OpenMusicSync` from the local package. `project.yml` is the XcodeGen spec. The generated `OpenMusic.xcodeproj` is gitignored.

## Install on your iPhone

There is no App Store build, and releases include no `.ipa` yet. You build it on a Mac with Xcode 27 and run it on your iPhone with your own Apple ID; a free Apple ID works.

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.
2. In the repository, generate the project and open it:

   ```bash
   xcodegen generate --spec iOS/project.yml
   open iOS/OpenMusic.xcodeproj
   ```

3. Select the `OpenMusic` target, open **Signing & Capabilities**, turn on **Automatically manage signing** and choose your Apple ID's team (add your Apple ID in Xcode's Settings › Accounts if it isn't listed). If Xcode says the bundle identifier is taken, change it to something of your own, such as `com.yourname.openmusic`.
4. Connect your iPhone, turn on Developer Mode if iOS asks (Settings › Privacy & Security › Developer Mode), choose it as the run destination and press Run.

Apps signed with a free Apple ID stop opening after 7 days; run the app from Xcode again to renew it. To keep it signed without a Mac nearby, [AltStore](https://altstore.io) and [SideStore](https://sidestore.io) can sign and refresh an `.ipa` you export from Xcode (Product › Archive) with your own Apple ID.

`project.yml` sets manual ad-hoc signing with no team, so command-line Simulator builds need none. Your signing choice lives only in the generated project, which is gitignored; running `xcodegen generate` again resets it, so repeat step 3 after that.

## Run in the Simulator

Open the project as above, pick an iPhone simulator and press Run. Launch arguments (Product › Scheme › Edit Scheme › Arguments):

- `-OpenMusicMock YES`: made-up sample data, no network. `-OpenMusicSignedOut YES` with it shows the signed-out state.
- `-OpenMusicScreen <name>`: opens one screen (see `App/SnapshotDriver.swift` for the names).
- `-OpenMusicSelfTest live`, `-OpenMusicSyncDeviceName "<name>"`.
- Debug builds only, read from the command line and never from saved defaults: `-OpenMusicSyncSelfTest YES` (sync log, `openmusic://test/…` commands and the probe's fake test sign-ins, see `Sync/SyncSelfTest.swift`) and `-OpenMusicOpenURL <link>` (opens an `openmusic://` link at once, during launch). Release builds compile none of this.

The maintainers drive the same builds on a remote Mac with `scripts/ios.sh` ([docs/maintainers.md](../docs/maintainers.md#build-mac)).

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
