# History

How OpenMusic got to its current design: migrations, removed features, and dated verification runs. Nothing here describes how the code works today; the [design documents](README.md#design) do. Kept because it explains choices that still show in the code, and because a server set up from an older version may need the [upgrade steps](self-hosting.md#upgrading-from-older-servers).

## The name

OpenMusic was called Medley until its first public release. The rename changed module, namespace, bundle and setting names; strings that existing installs, saved sign-ins or sync between versions depend on kept the old name, and the old `MEDLEY_*` environment variables and `-Medley*` launch arguments still work ([AGENTS.md](../AGENTS.md#names)). A self-hosted server set up before the rename keeps working after the steps in [self-hosting](self-hosting.md#upgrading-from-older-servers). On the hosted service, sign-ins made against the Clerk instance and Convex deployments from before the rename were not migrated: those devices signed in again. The old Convex project was left as it was.

## Accounts

Devices first paired with QR codes and invite codes. Accounts replaced pairing: you sign in with Clerk on each device, and the sign-in key moves between devices through the six-digit verification exchange ([accounts design](accounts-design.md)).

### Migration of paired devices

The simplest acceptable story: existing paired devices are asked to sign in once, and old library data expires.

- When the new backend is deployed, old libraries have no owner. Old builds' tokens still name devices in them, but `authenticate` refuses them (`unauthorized`), so an old build shows "This device was removed from your devices" and unpairs. The legacy sweep then deletes those libraries with their playback, vault and settings rows within minutes.
- A new build finds old `sync.credentials` without a device key pair; it drops them (they belong to a pairing), keeps its local YouTube Music and Spotify sign-ins untouched, and shows the welcome screen once.
- Synced settings and recent searches stay on each device locally; the first device to sign in fills the account with its values (`ifAbsent`), as a first device does today.
- Deploy order: the dev deployment first (its env vars set), then production. Both need `CLERK_JWT_ISSUER_DOMAIN` set before the push, or Convex refuses `auth.config.ts`.

### Migration to sealed content

The sealed playback, queue, command and settings fields replace the plaintext ones, and the schema push validates every stored row, so those tables must be empty when the new code is pushed. No released app wrote them. On dev (`sensible-barracuda-214`) all four tables (and `settingOps`) held no rows at the push on 2026-11-07, so nothing had to be cleared: the e2e runs sign their devices out, which deletes their rows. For any deployment that has rows (production, a self-hosted server), clear `playback`, `queues`, `commands`, `settings` and `settingOps` first (dashboard › Data › the table › Clear table), then deploy. Apps that published plaintext stop working against the new server until they are updated: their writes are refused as invalid arguments.

### Removed with pairing

- QR codes and invite codes: `invites:*`, `libraries:create`, `PairingLink`, `KeyShareLink`, `Invite`, `InviteQRCode`, `InvitePreview`, `SyncService.createLibrary/createInvite/previewInvite/redeem/keyShareLink/importKey`.
- The redeem and create rate limits and their residual-risk analysis (no guessable secrets remain).
- `openmusic://pair` and `openmusic://key` links, the Join and Invite sheets on the Mac, the scanner and Pair sheet on iOS, the link consent sheet, the "scan the QR code to sync sign-ins" card.
- The `openmusic://` URL scheme stays registered: it now carries the Clerk OAuth callback (`openmusic://oauth-callback`).

### Schema and function changes

What the move to accounts changed in `sync/convex/schema.ts`:

| Table | Change |
| --- | --- |
| `libraries` | Adds `owner` (Clerk token identifier) with index `by_owner`, `keyRotation?` (`{ neededSince }`), `retiredKeyIds?` and `keyRevision?` (Observations are monotonic). `pairedAt` and `createRequestHash` stay optional for old rows only; the `by_createRequestHash` index goes. |
| `devices` | Unchanged shape. `tokenHash` is now the hash of the device-generated token. |
| `deviceKeys` (new) | `libraryId`, `deviceId`, `publicKey` (base64, 32 bytes), `state` (discriminated union above, with `exchange` on `requested` and `rekey` on `holder`), `exposedKeyId?` (the newest key the device was given; see Removal), `updatedAt`. Indexes `by_device`, `by_library`. |
| `invites`, `redeemFailures` | No longer used. Declared as legacy so old rows validate; the legacy sweep empties them. |
| `vault` | Adds `cleared?` (Reset). |
| `cancelledRegistrations` (new) | `tokenHash`, `owner`, `reason?` (`retired`: its device was removed, by any path; `withdrawn`: `account:unregister` of a token no device of the user's has; missing on rows written before the field existed, which count as `withdrawn`), `createdAt`, `expiresAt`: device tokens `account:register` refuses for that user. Indexes `by_tokenHash_owner`, `by_owner_reason_expiresAt` (the withdrawal cap, which counts `withdrawn` and missing alike), `by_expiresAt`; swept hourly after 30 days (`account:sweepCancellations`). |
| `playback`, `queues`, `commands`, `settings` | What plays, queues, takeovers, command messages and setting values are sealed fields (`{ v: 1, keyId, sealed }`); the anchor, counters, command kinds and setting keys stay readable (`docs/sync-design.md`, "What the server can see"). Existing rows were cleared before the push (Migration). |
| `libraries` | Also `previousKey?` (`{ keyId, until }`). |
| `devices.platform` | Takes `windows`, `android` and `linux` too. |
| `settingOps`, `throttles` | Unchanged. |

`cancelledRegistrations.reason` is optional for the same kind of reason: the dev deployment already holds rows written before it existed, and a required field would make the schema push fail on them. Every reader treats a missing reason as `withdrawn`, so those rows refuse their tokens and count toward the per-user withdrawal cap. Deploy order, per deployment (dev first, then production): (1) push this schema and code (`reason` optional); (2) run the backfill, `npx convex run account:backfillCancellationReasons` (through `scripts/convex.sh`), which patches `LIMITS.sweepBatch` rows per run and schedules the next run until the table is done, and is safe to repeat; (3) once it has finished on both deployments, a follow-up change makes `reason` required. Step 3 is not in this change.

`owner` is optional in the schema only because libraries from before accounts exist in the dev and production deployments and must validate on push. New code never creates a library without one, and the legacy sweep deletes those that lack it. A later change can make it required once both deployments have swept.

And in the functions:

| Function | Change |
| --- | --- |
| `config:get` | New public query. |
| `account:register` | New. Returns `keyRevision` too. Refuses retired and withdrawn tokens (`unauthorized`). Takes `createdAt` (when the device made this registration, the same in every attempt) and refuses to create a device from an attempt older than 14 days or more than a day ahead (`invalidArgument`); a retry of an existing device is answered at any age. |
| `account:backfillCancellationReasons` | New, internal: the one-off migration that gives `cancelledRegistrations` rows without a `reason` the value `withdrawn`, in bounded runs (Data model changes). |
| `account:unregister` | New: removes the device a token names, for the signed-in user only (retiring its token), or records a withdrawal of a token no device of theirs has (rate limited and capped per user; a retry is free), so a registration with that token never lands afterwards. Answers `{ removed, cancelled }`. For a device that never learned its id. |
| `keys:claim` | Was `libraries:setKey`; only for a library without a key, never a retired key, and only at the `keyRevision` the device examined (required; `conflict` otherwise). Marks the caller `holder`. Answers with the revision after it. |
| `keys:request`, `keys:answer`, `keys:reveal`, `keys:grant`, `keys:accept`, `keys:deny` | New: the exchange. `keys:request` also resets a stranded key (Reset). |
| `keys:rotate` | New: replaces the key (Rotation). Answers with the revision after it. |
| `keys:release` | New: a holder whose key isn't the account's and that can't reach the current one becomes `requested` (Rotation); refused for the account's key, and unless the account's key, the rotated key waiting for the device and the key revision are the ones it examined (`accountKeyId`, `rekeyKeyId`, `keyRevision`, all required). |
| `devices:list` | Each device gains `keyState`, `publicKey` and, while `requested`, `exchange`. The caller's own grant comes back as `grant` and a rotated key waiting for it as `rekey` (or null); `rotationNeeded` says the key must be replaced; `keyRevision` orders lists. |
| `devices:remove` | Also retires the device's token, deletes its `deviceKeys` row, marks the key for rotation when the device may have the current key, and resets it when nobody left can open the vault. The last device out retires the library. |
| `devices:heartbeat` | A device without the key also resets a stranded key (Reset). |
| Every function taking `token` | Also requires the Clerk identity that owns the device's library. |
| `libraries:create`, `invites:create`, `invites:redeem`, `invites:preview`, `invites:sweep` | Removed. |

Crons kept: commands, throttles, settings writes (unchanged), and the hourly library sweep. Libraries now expire after 60 days with no device seen (one limit; the 7-day "never paired" limit goes, since a one-device library is normal now). Coming back after that is harmless: the next launch registers again as the first device of a new library.

Deleting a library (the last device left, or it expired) **retires** it: the owner is detached at once, so its tokens stop working and the user's next device starts a new library, and `legacy:sweep` deletes the rows in the background. `legacy:sweep` runs every 10 minutes and right after a library is retired. It deletes owner-less libraries with everything below them (vault, settings, settings writes, key rows, playback, then each device with its queue and commands, then the library), then invites and old counters, at most 1,000 rows per run in all (`LIMITS.librarySweepRows`), however large one library is: invites take from what the libraries left of the budget, and counters from what the invites left. A run that reaches the budget schedules the next, which picks up from what is still in the database.

Libraries used to expire 7 days after creation when never paired; with accounts a one-device library is normal, so the single 60-day limit replaced it.

### Design reviews

The account and key-exchange code went through repeated adversarial reviews before release. Each review's race cases became tests that fail on the code before their fix: the third review's in `KeyExchangeAndRegistrationRaceTests`, the fourth's in `StaleListAndIdentityRaceTests`, the fifth's in `AccountChangeResumeTests`, the sixth's in `IdentityChangeRaceTests`, the seventh's in `DeviceTokenRetirementTests` and the eighth's in `ClerkSessionEndTests`. Five reviews in a row found the same class of bug (a stale answer or a suspended operation resuming after another one changed the account), which is why every account operation now runs on one serial executor ([accounts design](accounts-design.md#account-operations-run-one-at-a-time)). The tenth added saving a granted key before acknowledging it.

## Keychain

The old stdin/stdout helper (`Contents/Helpers/medley-keychain`, service `app.medley.helper`) is gone, with no migration: no build anyone kept used the helper, and it could be hijacked by a process that spawned it and exec'd OpenMusic. Items it saved on the build Mac are abandoned. Items saved by the first service build (service `app.medley.keychain`) are abandoned too, and so are the pre-rename service's (`app.medley.keychain.v2`, bundle id `app.medley.Medley`): the rename to OpenMusic changed the bundle id, the service and its item name, with no migration.

## Verification runs

### Accounts, live (2026-11-07)

- Live, against the dev deployment and the OpenMusic Clerk development instance `helped-terrier-5339`: `scripts/e2e-sync.sh` signs the Mac app and the iPhone simulator in with the `+clerk_test` user through the real sign-in sheets (the email and the code `424242` typed into the focused field), checks registration and both device lists, the exchange both ways (the code on the holder's alert equal to the new device's, the alert on screen, Don't Allow then Ask Again bringing it back with a new code, Allow there and Codes Match here), Play Here and send back, a test sign-in reaching the other device through the vault, and sign-out. Green run of 2026-11-07 (24 checks): email typed to registered 10.8 s on the Mac and 9.8 s on the iPhone (each including about 5 s of scripted captures between the email and the code); asked to both showing a code 0.6–0.8 s; Allow to the key in use 0.6–1.1 s; Play Here 1.1 s; send back 0.8 s; a sign-in on the Mac to signed in on the iPhone 0.6 s.
- What the live runs found, each fixed with a test: the "Allow …?" alert never came up on either app (`keyRequests` began with the unobserved `credentials`, so a view that first read it before sign-in never heard of a request: `aViewReadingTheRequestsBeforeSignInHearsOfTheRequest`; snapshots set the observed `previewRequests` and missed it); the Mac app crashed when a request ended while SwiftUI's alert was up (it closed the `NSAlert` sheet itself mid-layout), so the Mac alert is an `NSAlert` run by `KeyRequestPrompter`; and from the reviews of the merge, a device asking again after Don't Allow got no alert (dismissals are per exchange, `DismissedKeyRequests`) and a stale Don't Allow could deny a newer exchange (`keys:deny` takes the commitment).

### Sealed content, live (2026-11-07)

- Live, sealed (2026-11-07, six runs of `scripts/e2e-sync.sh` with `OPENMUSIC_E2E_HOLD=1`, a `+clerk_test` user of its own; three before the review fixes, three after, with the iPhone app rebuilt for the last; the fifth lost only its probe step, to a test JWT that had expired): before the iPhone had the key it showed `REMOTE-STATE Mac: playing "(sealed)"`, a banner without a title and "This device doesn't have your sign-in key yet…" on Play Here, and paused the Mac remotely; with the key, Play Here and send back with real YouTube streams, remote pause and play, recent searches, a sign-in through the vault; a third device (openmusic-probe) took the key and was removed, the key rotated, and both apps read each other's titles and handed off. A dump of every table while the account still had its rows (`npx convex export`) held none of the titles, artists, album, track ids, artwork hosts or searches played, only fingerprints, anchors and sealed blobs; the only URLs were the Clerk issuer in `owner`. `windows/scripts/live-cross-platform.sh` (C# and Swift probes): the C# device showed the Swift device's playback as "(sealed)" until it had the key, then pulled and pushed playback and sent remote commands.
