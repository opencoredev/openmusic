# OpenMusic Sync: design and contract

OpenMusic Sync lets you open OpenMusic on any of your devices (Mac, iPhone, Windows) and pick up exactly what another device is playing: track, position, queue, shuffle and repeat. You can also send playback to another device and control one device from another, like Spotify Connect. Sign-ins (YouTube Music, Spotify) and settings (playback preferences, recent searches) stay the same on every device too. Everything that says what you listen to or search for is end-to-end encrypted, along with the sign-ins.

## What the server can see

OpenMusic's promise: we don't track what you're listening to. The sync server, and whoever runs it (us for the hosted server, you if you run your own), sees that your devices exist, when they're online, and where playback is ("playing, 2 minutes 13 seconds in"). It never sees what is playing, what is in your queue, what you searched for or which settings you chose.

How: the first device you sign in on makes a secret key, the **sign-in key**, and gives it only to devices you approve with the six-digit code (docs/accounts-design.md). Before anything about a song leaves a device, the device locks it with that key. The server stores the locked version and passes it on; it doesn't have the key, so it can't unlock it. The other devices that have the key unlock it and show the song.

Every field the server stores:

| Where | Field | What it is | The server sees it? |
| --- | --- | --- | --- |
| Your account | `owner` | Your Clerk user id (Clerk's address plus a random id; no email or name) | Yes |
| | `createdAt`, `expiresAt` | When the account was made, and when it is deleted if no device is seen for 60 days | Yes |
| | `keyId`, `retiredKeyIds`, `previousKey`, `keyRotation`, `keyRevision` | Fingerprints of the sign-in key (current and past) and counters for changes to it. A fingerprint can't be turned back into the key. | Yes |
| Each device | `name`, `platform`, `model`, `appVersion` | "Riley's Mac", `mac`, "Mac16,10", "1.0" | Yes |
| | `createdAt`, `lastSeenAt` | When it joined, when it last talked to the server | Yes |
| | `tokenHash` | A hash of the device's secret token (the token itself never leaves the device) | Only the hash |
| Key exchange | `publicKey`, `state` (commitments, nonces, the six-digit-code exchange) | Public values the devices swap to agree on the code | Yes (public by design) |
| | `wrapped` (in a grant or rotation) | The sign-in key, locked for one device | Locked |
| Playback (one per device) | `anchor`: `positionMs`, `positionAt`, `isPlaying`, `rate`, `durationMs`, `volume`, `shuffle`, `repeat` | Where playback is and how: "playing, 2:13 of 6:09, volume 50%, shuffle off" | Yes |
| | `queueVersion`, `updatedAt` | A counter that changes when the queue changes, and when it was last updated | Yes |
| | `content` | The current song (title, artists, album, artwork link, the service's track id), its place in the queue, the queue's length | **Locked** |
| Queue (one per device) | `content` | Up to 20 songs before the current one and 100 after it, with where each came from (album, playlist, radio) | **Locked** |
| | `version` | The same counter | Yes |
| Remote commands | `kind`, sender, target, `createdAt`, `expiresAt`, `ackedAt` | "pause", "next", "seek", from which device to which, when | Yes |
| | `positionMs` (seek), `volume` (set volume) | The number in a seek or volume command | Yes |
| | a takeover's `anchor` | Where playback continues | Yes |
| | a takeover's `content` | The queue that moves to the other device | **Locked** |
| | `result.ok`, `result.reason` | Whether it worked and, if not, why as a code from a fixed list (`expired`, `needsKey`, `playbackFailed`, …) | Yes |
| | `result.content` | The full error message, which can name the song ("“Get Lucky” couldn't be loaded") | **Locked** |
| Settings | `key`, `updatedAt`, `updatedBy`, `writeId` | Which setting changed and when: `search.recent`, `playback.crossfadeSeconds`, `playback.autoplay`, `playback.normalizeVolume`, `playback.sleepTimerMinutes` | Yes |
| | `value` | Your recent searches, your crossfade length, autoplay on or off… | **Locked** |
| Sign-ins (one per service) | `provider`, `revision`, `keyId`, `updatedAt`, `updatedBy`, `cleared` | That you have a YouTube Music or Spotify sign-in synced, and when it changed | Yes |
| | `sealed` | The sign-in itself (cookie or token) | **Locked** |
| Housekeeping | `settingOps`, `throttles`, `cancelledRegistrations` | Recent write ids, rate-limit counters, hashes of device tokens that may not register again | Yes (no content) |

What the visible parts can still give away, so nothing here is a surprise:

- When you listen, on which device, for how long, and roughly how big your queue and your recent-searches list are (a locked field is about as long as what's inside it).
- The length of the current song (`durationMs`). Many songs share a length, but a server that wanted to guess could try to match it against a catalogue together with the times you skip.
- Which services you have synced sign-ins for, and which of the five settings you changed.
- The server could replay an older locked value from the same device and the same place (show your phone's queue from an hour ago) or withhold updates. It can't make up content, move one device's content to another, or read any of it.

A device that doesn't have the sign-in key yet (just signed in, waiting for you to tap Allow) still shows the other devices and where they are, "Playing on Riley's Mac · 2:13", without the song, and can still pause or skip them. It publishes only its own position. Moving playback to or from it needs the key, and the app says so. Settings and recent searches sync once it has the key.

### How the locking works

- One key per kind of data, derived from the sign-in key: `HKDF-SHA256(sign-in key, info "medley.content.v1.<kind>")` for `playback`, `queue`, `command`, `result` and `setting`. None of them is the sign-in key, and none is used for two kinds.
- AES-256-GCM with a new random 12-byte nonce for every seal, stored as `{ v: 1, keyId, sealed }` with `sealed` the base64 of nonce, ciphertext and tag.
- The authenticated data binds each blob to where it belongs: `medley.content.v1` followed by the kind, the account (library) id, the id of the device that wrote it, the key's fingerprint, and the setting key (for settings), the target device (for a takeover) or the command id (for a result), each length-prefixed. A blob opens only in that place; moved anywhere else it fails to open, and the reader ignores it.
- Swift: `Sources/MedleySync/Keys/ContentSealing.swift`. C#: `windows/Medley.Sync/Keys/ContentSealing.cs`, checked against vectors made by the Swift code (`windows/Medley.Sync.Tests/Vectors/swift-content-vectors.json`) and the other way round.
- The server checks only the shape: version 1, a 32-hex fingerprint the account accepts, base64 of a plausible length for the kind. Settings must be sealed with the account's current key. What a device publishes about itself (playback, queue, commands, results) may also use the key the last rotation replaced, for 10 minutes, so a device that hasn't picked up the new key yet isn't refused. A song or search in the clear is refused: the server's validators no longer have fields for them.
- When the sign-in key is replaced (a device that had it leaves), the device that replaces it re-locks every settings value in the same step (`keys:rotate`), and every device that has the key publishes its playback and queue again under the new one. Readers skip blobs under a key they don't have, so for a moment another device may show without its song.
- When nobody has the key any more (the last device that had it left), the settings are deleted (nobody can unlock them), and the next device to make a key fills them in from its own.

Devices sync through a OpenMusic account: sign in with Clerk on each device and every device of the same user is in the same sync group. `docs/accounts-design.md` explains the accounts (identity, registration, how the sign-in key moves between devices, server choice, migration); `docs/self-hosting.md` covers running your own server.

This page is the contract between the backend (`sync/convex/`), the Swift client (`Sources/MedleySync/`) and the apps. The sync worker owns it. The Mac and iOS sync-UI workers build against the sections [How an app wires sync](#how-an-app-wires-sync) and [Swift API](#swift-api).

## How it works

- A **library** is one account's sync group: every device signed in to the same Clerk user (`libraries.owner` is the identity's `tokenIdentifier`). Calls carry the Clerk JWT (Convex auth); every function but `config:get` needs it. Each device also makes a secret 32-byte **token** when it registers (`account:register`), and every function takes it to know which device is calling; the server stores only its SHA-256 and checks that the device belongs to the signed-in user's library.
- Each device publishes its **playback**. This is a small row with a position **anchor** in the clear and the current track sealed, plus a separate sealed **queue window** of up to 20 entries before the current one and 100 after it (What the server can see). Position travels as an anchor (`positionMs` was true at server time `positionAt`), never as a stream of ticks. A device without the sign-in key publishes its anchor alone.
- Devices talk through **commands** (`play`, `pause`, `takeOver`, …). The target runs a command and **acks** it with a result. Commands expire 2 minutes after they're sent.
- **Pull handoff** (`playHere(from:)`): fetch the source's queue window, cue it paused at the source's live position, seek to the position it has reached by the time the stream is ready, play, and only then send `pause` to the source.
- **Push handoff** (`send(to:)`): send `takeOver` with the local queue window (sealed for the target) and anchor. The target cues it, plays, then acks. The sender pauses when the ack says `ok`. Both handoffs need the sign-in key on both devices.
- **Library key** (the sign-in key). The first device generates a 32-byte AES key for the account and keeps it in its Keychain. The key never reaches the server, which stores only a fingerprint (`keyId`). It reaches a new device through a verification exchange: both devices show the same six-digit code, the listener taps Allow on the device that has the key and Codes Match on the new one, and the key arrives sealed so only those two devices can open it (`keys:request` / `answer` / `reveal` / `grant`; see the accounts design). Until then the new device sees where the others play but not what, can control them, and syncs no sign-ins and no settings. When a device that could open the vault leaves, a remaining holder replaces the key (`keys:rotate`).
- **Vault.** For each library and provider (`youtubeMusic`, `spotify`) there is one AES-GCM blob sealed with the library key, plus a `revision`, `updatedAt` and `updatedBy`. Every write (sign-in or sign-out) bumps the revision by one, and the blob is sealed for exactly the revision it gets, so an old blob can't be replayed later. When a device signs in, or its provider rotates a token, it seals the new sign-in and writes it with compare-and-swap on the revision it last saw. Every other device that holds the key opens it and imports it. A device ignores its own writes when they come back. "Sign out everywhere" replaces the blob with a tombstone at the next revision, and every device signs out, including devices without the key. A device that missed the tombstone can't overwrite it: its write is based on an older revision and the server refuses it. If the tombstone was then covered by a blob that doesn't open at its revision (an old one replayed), the device signs out anyway and uploads nothing: only a fresh sign-in replaces such an entry.
- **Settings.** JSON per key, sealed with the sign-in key, last write wins per key, library-wide: Sound Check, crossfade, autoplay, the sleep-timer preset and recent searches. Volume and the output device stay per device.

### Live numbers (dev deployment, two probe processes on the build Mac)

| What | Measured |
| --- | --- |
| Command delivery, sent to arrival at the target (server clock, 20 commands) | 43–68 ms, median ~53 ms |
| Remote tap to the ack seen by the sender | 169–293 ms, median ~199 ms |
| Pull handoff, tap to playing (mock engine, no stream resolution) | 56–70 ms |
| Push handoff, tap to the target acking that it plays | 221–257 ms |
| Position after handoff vs the source | within ±0.5 s (the mock engine advances in 0.5 s steps) |
| Sign-in written on A to decrypted and imported on B (fake sign-ins, server clock) | 37–55 ms, including the rotated token and "sign out everywhere" |
| Setting changed on A to applied on B (after the 400 ms debounce) | 40–46 ms |

With real streams, the pull gap is roughly the time it takes to resolve one stream.

Sealing costs little. The same live check (`scripts/e2e-sync.sh`: the Mac app and the iPhone simulator on the build Mac, real YouTube streams, dev deployment) before and after content was sealed, on 2026-11-07:

| What | Before sealing (one run) | Sealed (three runs) |
| --- | --- | --- |
| Play Here on the iPhone, tap to playing | 1.11 s | 1.10, 1.12, 1.12 s |
| Send to the Mac, tap to acked and paused here | 0.84 s | 0.58, 0.85, 0.59 s |
| Sign-in made on the Mac to signed in on the iPhone | 0.57 s | 0.58, 0.57, 0.56 s |
| Recent search on the Mac applied on the iPhone, after the write (server clock) | (probe: 40–46 ms) | 59, 55, 56 ms |
| Remote pause, tap to the ack seen on the iPhone | (probe: median ~199 ms) | 235, 225, 195 ms |
| Remote pause, tap to the Mac's player paused | not measured | 0.29, 0.56, 0.29 s |
| Play Here after a rotation (stream cached) | not measured | 0.57 s each run |

C# (Windows) and Swift probes on dev, sealed: pull 81 ms tap to playing (mock engine), push 168 ms, remote commands acked 156–161 ms.

## Backend

Convex project `openmusic`. The dev deployment is `sensible-barracuda-214`, at `https://sensible-barracuda-214.convex.cloud`; production is `insightful-roadrunner-835`. The apps read the hosted URL from the `OpenMusicSyncURL` Info.plist key and, without it, use dev in a Debug build and production in a Release build (`SyncService.deploymentURL(bundle:)`; Windows: `SyncHub.HostedUrl`); a custom server the listener entered (`SyncServer`, UserDefaults `syncServerURL`) replaces it. Both deployments need `CLERK_JWT_ISSUER_DOMAIN` and `CLERK_PUBLISHABLE_KEY` set (docs/self-hosting.md), and both have them for the OpenMusic Clerk development instance: `CLERK_JWT_ISSUER_DOMAIN=https://helped-terrier-5339.clerk.accounts.dev`, `CLERK_PUBLISHABLE_KEY=pk_test_aGVscGVkLXRlcnJpZXItNTMzOS5jbGVyay5hY2NvdW50cy5kZXYk` (AGENTS.md has the instance's other facts).

Run every Convex command from a worktree through `scripts/convex.sh '<cmd>'`. It runs in `~/agents/openmusic-sync` on the machine where the Convex CLI is logged in (`OPENMUSIC_CONVEX_HOST` in `scripts/local.env`, or `local`).

```bash
scripts/convex.sh 'npx convex dev --once'                     # deploy to dev
scripts/convex.sh 'npx tsc -p convex --noEmit'                # typecheck
scripts/convex.sh 'timeout 180 npx vitest run --maxWorkers=2' # backend tests (convex-test)
```

### Tables

| Table | Fields | Indexes |
| --- | --- | --- |
| `libraries` | `owner?` (Clerk `tokenIdentifier`; missing on legacy rows and on retired libraries waiting for the sweep), `createdAt`, `keyId?` (library key fingerprint), `keyRotation?` (`{ neededSince }`), `retiredKeyIds?`, `keyRevision?`, `previousKey?` (`{ keyId, until }`: the key the last rotation replaced, taken for what a device publishes about itself until `until`), `expiresAt?`, legacy `pairedAt?` and `createRequestHash?` | `by_owner`, `by_expiresAt` |
| `devices` | `libraryId`, `name`, `platform` (`mac`\|`ios`\|`windows`\|`android`\|`linux`), `model`, `appVersion`, `tokenHash`, `createdAt`, `lastSeenAt` | `by_tokenHash`, `by_library` |
| `playback` | `libraryId`, `deviceId`, `content?` (`Sealed`, kind `playback`; missing from a device without the key), `queueVersion`, `anchor`, `updatedAt` | `by_device`, `by_library` |
| `queues` | `libraryId`, `deviceId`, `content` (`Sealed`, kind `queue`: ≤121 `QueueEntry` and the index), `version` | `by_device` |
| `commands` | `libraryId`, `fromDeviceId`, `toDeviceId`, `command` (a takeover's queue sealed), `createdAt`, `expiresAt`, `ackedAt?`, `result?` (`ok`, `reason?`, sealed `content?`), `clientId?` | `by_to_pending`, `by_from`, `by_from_clientId`, `by_expiresAt` |
| `deviceKeys` | `libraryId`, `deviceId`, `publicKey` (X25519, base64), `state` (`holder` with `rekey?` \| `requested` with `exchange?` \| `denied` \| `granted` with `wrapped`, `keyId` and `commitment`), `updatedAt` | `by_device`, `by_library` |
| `invites` | Legacy (invite codes). Kept so old rows validate; `legacy:sweep` empties it. | none |
| `vault` | `libraryId`, `provider`, `sealed?` (base64 AES-GCM; missing = tombstone, unless `cleared`), `cleared?` (the key was lost; not a sign-out), `keyId`, `revision?` (missing = 0), `updatedAt`, `updatedBy` | `by_library_provider` |
| `settings` | `libraryId`, `key`, `value` (`Sealed`, kind `setting`, always under the library's current key), `updatedAt`, `updatedBy`, `writeId?` | `by_library_key` |
| `settingOps` | `libraryId`, `key`, `writeId`, `deviceId`, `updatedAt`, `expiresAt` (10 minutes after the write) | `by_library_key_write`, `by_expiresAt` |
| `throttles` | `key` (`register:<hash of the user>`), `windowStart`, `count`, `blockedUntil?`, `expiresAt` | `by_key`, `by_expiresAt` |
| `redeemFailures` | Legacy (the old counters). Kept so old rows validate; `legacy:sweep` empties it. | none |

Crons: every minute `throttle:sweep` deletes finished rate-limit counters and `commands:sweep` commands past `expiresAt`, acked or not; every 5 minutes `settings:sweepOps` forgets settings writes older than 10 minutes; every 10 minutes (and right after a library is retired) `legacy:sweep` deletes owner-less libraries (paired ones, and libraries retired since) with all their rows, invites and old counters, at most 1,000 rows per run however large a library is. These delete in batches and, while a batch comes back full, schedule another run right away, so a backlog drains instead of growing. `libraries:sweepExpired` runs every hour and retires accounts nobody used for 60 days (see Library expiry below).

### Shared shapes (`sync/convex/model.ts`)

- `DeviceInfo`: `{ name, platform: "mac"|"ios"|"windows"|"android"|"linux", model, appVersion }`. The name is trimmed and must be 1–64 characters. Clients read a platform they don't know as unknown (a generic computer icon) rather than failing the device list.
- `Sealed`: `{ v: 1, keyId (32 hex), sealed (base64) }`, see What the server can see. What is inside (`Track`, `QueueEntry`, `PlaybackContext`) is exactly what `MedleyCore`'s `Codable` writes through `JSONEncoder`: missing optionals left out, URLs as strings, UUIDs uppercase. The `playback` kind holds `{ track, index, queueLength }`, `queue` and `command` hold a queue window `{ entries, index }`, `result` holds `{ message }`, `setting` the value's JSON text.
- `Anchor`: `{ positionMs, positionAt?, isPlaying, rate, durationMs?, volume (0…1), shuffle, repeat: "off"|"all"|"one" }`. On input the server clamps `positionAt` to `[now − 10 s, now]` and fills it with `now` when it is missing. Stored and returned anchors always have it.
- `Command`, discriminated by `kind`: `play`, `pause`, `toggle`, `next`, `previous`, `stop`, `{seek, positionMs}`, `{setVolume, volume}`, `{takeOver, anchor, content: Sealed}` (the queue window, kind `command`, the target device in the authenticated data).
- `CommandResult`: `{ ok: boolean, reason?: "expired"|"unavailable"|"nothingToPlay"|"needsKey"|"unreadable"|"providerUnavailable"|"playbackFailed"|"failed", content?: Sealed }`. A failure without a reason is stored as `failed`; a success takes no reason. The message, which can name a song, is only ever sealed (kind `result`, the command id bound in); without it the sender shows the reason's own words.

Live position is `positionMs + max(0, serverNow − positionAt) × rate` while playing, clamped to `durationMs`.

### Functions

Every argument and return has a `v.*` validator. Every mutation returns `serverNow` (server ms). Every function but `config:get` throws `ConvexError({code: "unauthenticated"})` without a Clerk identity (the client refreshes its token and retries). Functions that take `token` throw `unauthorized` for an unknown or removed device, or one of another user. A device id from another library throws `notFound`, the same as a missing one. Bad input throws `invalidArgument`. Other codes: `forbidden`, `rateLimited` (with `retryAfterMs`) and `conflict` (vault writes, with `revision`).

Every mutation the Swift client calls is safe to run twice, because the client retries a mutation over HTTP when the socket died before its answer arrived (see Client internals): `commands:send` dedupes by `clientId`, vault writes by revision, `settings:put` by `writeId` (remembered for 10 minutes), `account:register` by the device token (the same device comes back while it exists; once it is removed the token is retired and refused), `keys:grant` by the wrapped blob, `keys:request` / `answer` / `reveal` by the commitment and nonce, `keys:rotate` by the new key, and the rest are idempotent or harmless twice (`playback:publish`, `commands:ack`, `devices:heartbeat`, `devices:rename`, `keys:claim`, `keys:accept`, `keys:deny`; a second `devices:remove` of the caller throws `notFound`, which the client treats as done).

| Function | Kind | Args | Returns |
| --- | --- | --- | --- |
| `config:get` | query (public) | `{}` | `{ auth: { kind: "clerk", publishableKey } \| { kind: "notConfigured" } }` |
| `account:register` | mutation | `{ token (32–100 base64url), device: DeviceInfo, publicKey (X25519, base64), keyId?: string (32 hex) }` | `{ deviceId, libraryId, keyId: string\|null, keyState, serverNow }`. Creates the user's library on their first device; adopts `keyId` only when the library has none (and never a retired key); any other new device is `requested`. A full library (32) loses its stalest device. 30 new devices per user per hour, else `rateLimited`. |
| `keys:claim` | mutation | `{ token, keyId, keyRevision }` | `{ keyId, keyRevision, serverNow }`. Only for a library without a key, never a retired key; otherwise `forbidden` (a holder's retry of its own claim is a no-op). Only at the key revision the device examined (required; `conflict` otherwise). The caller becomes `holder`. |
| `keys:request` | mutation | `{ token, commitment: base64 (32 bytes) }` | `{ serverNow }`. Starts an exchange (`requested` with `exchange.phase` `committed`), dropping any earlier one, denial or grant; a holder stays one. 20 per device per hour, else `rateLimited`. |
| `keys:answer` | mutation | `{ token, deviceId, commitment, nonce: base64 (32 bytes) }` | `{ serverNow }`. A holder answers the target's current commitment (`answered`; the server adds the caller's public key). The first answer wins; others get `conflict`. |
| `keys:reveal` | mutation | `{ token, commitment, nonce }` | `{ serverNow }`. The caller reveals its nonce once answered (`revealed`). |
| `keys:grant` | mutation | `{ token, deviceId, keyId, wrapped: base64 (≤512), commitment }` | `{ serverNow }`. Only the holder that answered, for the revealed exchange named by `commitment`, with the library's `keyId`, and not while `keyRotation` is set (`conflict`). |
| `keys:accept` | mutation | `{ token, keyId }` | `{ serverNow }`. A `granted` caller becomes `holder`; a holder takes its `rekey`. |
| `keys:deny` | mutation | `{ token, deviceId }` | `{ serverNow }`. A holder says no; the target becomes `denied`. |
| `keys:rotate` | mutation | `{ token, fromKeyId, keyId, wraps: [{ deviceId, wrapped }], vault: [{ provider, baseRevision, sealed: string\|null }], settings: [{ key, baseUpdatedAt, value: Sealed\|null }] }` | `{ keyRevision, serverNow }`. A holder replaces the key: one wrap per other holder, one re-sealed blob per sealed vault row at its current revision, one re-sealed value (under the new key) per settings row at the `updatedAt` it read (`null` deletes the row), else `conflict`. Retires `fromKeyId` (kept as `previousKey` for 10 minutes), sets each holder's `rekey`, drops unaccepted grants and holders still behind. |
| `devices:list` | query | `{ token }` | `{ selfId, libraryId, keyId: string\|null, rotationNeeded, devices: [{ id, name, platform, model, appVersion, createdAt, lastSeenAt, keyState, publicKey, exchange (while requested) }], grant: { keyId, wrapped, fromDeviceId, commitment } \| null, rekey: { keyId, fromKeyId, wrapped, fromDeviceId } \| null }` (the caller's own pending grant and rotated key) |
| `devices:heartbeat` | mutation | `{ token }` | `{ serverNow }` |
| `devices:rename` | mutation | `{ token, deviceId, name }` | `{ serverNow }` |
| `devices:remove` | mutation | `{ token, deviceId }` | `{ serverNow }` |
| `playback:publish` | mutation | `{ token, anchor: Anchor, content?: { playback: Sealed, queue: Sealed } \| null }` | `{ serverNow, positionAt, queueVersion }`. `content` replaces what plays (both under one key), `null` drops it (a device without the key), left out keeps it. |
| `playback:clear` | mutation | `{ token }` | `{ serverNow }` |
| `playback:list` | query | `{ token }` | `[{ deviceId, content: Sealed\|null, queueVersion, anchor, updatedAt }]` |
| `playback:queue` | query | `{ token, deviceId }` | `{ content: Sealed, version }` or `null` |
| `commands:send` | mutation | `{ token, toDeviceId, command: Command, clientId?: string (1–64) }` | `{ commandId, expiresAt, serverNow }`. The same `clientId` again returns the stored command. |
| `commands:incoming` | query | `{ token }` | `[{ id, fromDeviceId, command, createdAt, expiresAt }]`, unacked and oldest first, at most 50 |
| `commands:ack` | mutation | `{ token, commandId, result: CommandResult }` | `{ serverNow }`. A free-text message in the clear is refused. |
| `commands:outgoing` | query | `{ token }` | `[{ id, toDeviceId, kind, createdAt, expiresAt, ackedAt?, result? }]`, newest 20 |
| `vault:list` | query | `{ token }` | `[{ provider, sealed: string\|null, cleared, keyId, revision, updatedAt, updatedBy }]` |
| `vault:put` | mutation | `{ token, provider, sealed: base64 (≤64 KB), keyId, baseRevision?: int }` | `{ updatedAt, revision, serverNow }`. A stale `baseRevision` throws `conflict` with the stored `revision`. Without `baseRevision` the row stays at revision 0 (see Vault below). |
| `vault:signOutEverywhere` | mutation | `{ token, provider, baseRevision?: int }` | `{ updatedAt, revision, serverNow }`; leaves a tombstone |
| `settings:list` | query | `{ token }` | `[{ key, value: Sealed, updatedAt, updatedBy, writeId? }]` |
| `settings:put` | mutation | `{ token, key: [A-Za-z0-9._-]{1,64}, value: Sealed (≤44 KB of base64: 32 KB of JSON), writeId?: string (1–64), ifAbsent?: boolean }` | `{ updatedAt, serverNow }`. At most 64 keys per library. Only under the library's current key. |
| `throttle:sweep`, `settings:sweepOps`, `commands:sweep`, `libraries:sweepExpired`, `legacy:sweep` | internal mutation | `{}` | counts (and `more` for the batched sweeps) |

Rules the functions enforce:

- **Accounts.** One library per Clerk user, keyed by `tokenIdentifier`, so users of different Clerk apps never mix. A device belongs to the library it registered in; another user's identity with its token gets `unauthorized`. Libraries without an owner (from before accounts) refuse every token.
- **Vault.** `vault:put` requires `keyId` to equal the library's key fingerprint, so a device holding the wrong key can't overwrite readable data, and is refused (`forbidden`) while the key is being replaced. The server never sees plaintext or the key; a raw row holds only `sealed` (base64 ciphertext), `keyId`, `provider`, `revision`, `updatedAt` and `updatedBy`. Each write gets `revision = previous + 1` and `updatedAt = max(now, previous + 1)`. With `baseRevision`, a write is accepted only if the stored revision still equals it (compare and swap); otherwise it throws `conflict`. A retry of a write that already landed (same device, same ciphertext or tombstone, stored revision `baseRevision + 1`) returns that write. A `vault:put` without `baseRevision` comes from a client from before revisions, which seals in the v1 format; it writes at revision 0 (the only revision current clients open v1 at) and is refused with `conflict` once the row is a tombstone or has a revision above 0. Current clients migrate a revision-0 row by writing it again in the v2 format with `baseRevision: 0`, so exactly one migration wins.
- **Sealed content.** Every sealed field is checked for its shape only: `v` 1, a `keyId` the library accepts (its key; for playback, queues, takeovers and results also `previousKey` until it expires; nothing at all while the library has no key, `forbidden`), base64 of 40 bytes up to the kind's bound (`SEALED_MAX` in `content.ts`). The validators have no fields for a track, a queue, a message or a setting in the clear.
- **Settings.** `settings:put` stamps `updatedAt` the same way and checks the key's form and the sealed value. Each write with a `writeId` is remembered in `settingOps` for 10 minutes: putting the same `writeId` again (from the same device) returns the `updatedAt` it got and changes nothing, even when another device wrote the key in between. After that, a put with the `writeId` the row still holds is a no-op too. With `ifAbsent`, an existing value is kept.
- **Rate limit (registration).** 30 new devices per user per hour; retries of a registration don't count.
- **Library expiry.** A library expires 60 days after any of its devices was last seen. Heartbeats move `expiresAt` forward (at most once an hour). The hourly sweep checks the devices' `lastSeenAt` again before retiring the library: its owner is detached at once and `legacy:sweep` deletes its devices, key rows, playback, queues, commands, vault and settings in bounded runs. A device coming back after that gets `unauthorized` and signs in again.
- **Publish.** Leave `content` out for anchor-only updates and the stored content and window are kept; `null` drops them and bumps `queueVersion`. A first publish may carry no content. Each publish also refreshes `lastSeenAt`.
- **Commands.** Commands go only to another device in the same library, never to yourself. Only the target can ack, and acking twice keeps the first result.
- **Remove.** Removing a device deletes it along with its playback, queue, commands (to and from it) and key row; exchanges it was answering start over. The last device out retires the library (its vault and settings go with the sweep). When the removed device could open the vault (`holder` or `granted`) and others still can, `keyRotation` is set until a holder calls `keys:rotate`. When no remaining device can open the vault, `keyId` is cleared and retired, sealed vault rows become `cleared` at their next revision (tombstones stay), settings rows are deleted (sealed under the lost key), and every device becomes `requested`; the next one claims a fresh key.
- **Online.** A device is online when `serverNow − lastSeenAt < 90 s`. Clients compute this, because a reactive query doesn't rerun as time passes.

## Swift API

`import MedleySync`. It has no dependencies beyond Apple frameworks and builds for macOS 15 and iOS 26. All UI-facing types are `@MainActor` and `@Observable`.

### `SyncService`

The sync session of this device. Create one per app and keep it for the app's lifetime.

```swift
init(deploymentURL: URL = SyncService.deploymentURL(),     // Info.plist OpenMusicSyncURL, else dev
     deviceInfo: DeviceInfo,                                // DeviceInfo.current()
     credentials: any SyncCredentialStore = KeychainCredentialStore(),
     transport: any WebSocketTransport = URLSessionWebSocketTransport(),
     http: any HTTPPoster = URLSessionHTTPPoster(),
     options: ConvexClient.Options = .init())
```

Observable state that the UI reads:

| Property | Meaning |
| --- | --- |
| `registration: Registration` | `.none` or `.registered(deviceID:libraryID:)`. `isRegistered`, `selfID` and `selfDevice` derive from it. |
| `devices: [SyncDevice]` | Every device in the library, this one included, oldest first. `otherDevices` leaves this one out. |
| `playback: [DeviceID: RemotePlayback]` | Published playback per device, this one included. A device with nothing loaded has no entry. `track`, `index` and `queueLength` are nil when the content is sealed under a key this device doesn't hold, or the device published none (`content`: `.open`, `.sealed`, `.none`); `trackLine` is "Title · Artist" or nil. Show those rows as "Playing on <device> · 2:13". |
| `canSealContent` | This device holds the account's current key, so it publishes what plays and can hand off. |
| `outgoing: [OutgoingCommand]` / `incoming: [IncomingCommand]` | Recent sent commands with their ack state, and unacked commands for this device. |
| `connection: ConvexClient.Status` | `state` is `.idle`, `.connecting`, `.connected`, `.waitingToReconnect(attempt:)` or `.stopped`, plus `httpFallback` and `connections`. |
| `lastError: SyncError?` | The last error from a live query, or `.removedFromLibrary` once this device's token stops working (`onRemoved` runs then; the apps sign out). |
| `clock: ServerClock` | Server clock estimate. `clock.now()` is in server ms; `clock.localDate(_:)` converts a server time. |
| `keyStatus` | `.none`, `.available` (sign-ins sync), `.waiting` (asked; no holder answered yet), `.comparing(KeyComparison)` (show `code`; `allowed`, `confirmed`, `holderName`, and `title(here:)` / `instructions(here:)` for the card), `.denied`, `.failed(message)` (the attempt ended), `.mismatch`. |
| `keyRequests`, `keyHolders` | Other devices asking for the key whose exchange with this device checked out (only on a holder), each with its `code` and `commitment`; devices that hold it. |
| `keyWarning` | On a holder: failed, refused or tampered exchanges today, or answering paused. nil when all is well. |
| `rotationNeeded`, `vaultWritesPaused` | The key must be replaced (this device does it at once); nothing is written to the vault while the device isn't sure its key is the account's. |
| `signIns: SignInSync` | Sign-in sync. See below. |
| `settings: SettingsSync` | Settings sync. See below. |
| `vaultEntries`, `settingEntries`, `serverKeyID` | Raw live query results (nil until loaded). The UI rarely needs them. |

Helpers: `isOnline(_ device:)` and `livePosition(of:) -> TimeInterval?`.

Actions:

| Method | What it does |
| --- | --- |
| `start()` / `stop()` | Connect, and while registered keep 6 live queries open (`devices:list`, `vault:list`, `settings:list`, `playback:list`, `commands:incoming`, `commands:outgoing`). `start()` is idempotent. `stop()` sets `connection` to `.idle` right away. |
| `setForeground(_:)` | Call it on every scene-phase change. Heartbeats (every 30 s) and the HTTP fallback poll run only while the app is in the foreground or playing. Coming to the foreground reconnects at once. With `suspendsInBackground` (default on iOS, off on macOS) the socket closes `backgroundGrace` (10 s) after the app went to the background without playing, and reopens when it returns or starts playing; a call made meanwhile wakes it for that call. |
| `setPlaying(_:)` | `SyncCoordinator` calls it for you. |
| `signIn(auth:userID:)` | Sets the Convex token provider, registers this device with the account (once; a registration saved for another user is dropped first) and opens the live queries. Throws when registering fails; calling again retries the same registration. |
| `signOut()` | Removes this device on the server (best effort), forgets its token, keys and vault key, drops the identity and stops. |
| `allowKey(for:)`, `denyKey(for:)` | Answer a `KeyRequest` on a holder (Allow rotates first if needed, then seals the key for that exchange). |
| `confirmKeyCode()`, `rejectKeyCode()`, `requestKeyAgain()` | On the asking device: the codes match (the key is taken once the holder allowed it), they don't (the attempt ends), or start a new exchange. |
| `rename(_:to:)`, `remove(_:)`, `forget()` | Removing this device signs it out of sync. `forget()` only drops the local registration. Changing accounts drops everything kept for the old one: live results, queued commands, ack waiters (they throw `notPaired`), sign-in sync state and settings caches and pending writes. |
| `send(_:to:) -> CommandID`, `waitForAck(_:timeout:) -> CommandResult` | The raw command channel. Most UI goes through the coordinator instead. |
| `publish(anchor:queue:)`, `clearPlayback()`, `fetchQueue(of:)`, `ack(_:_:)` | Used by the coordinator. |
| `commandHandler` | Set by `SyncCoordinator.attach()`. Each incoming command runs once, in order, and is acked with the returned result. |

`SyncError` cases have user-facing `localizedDescription` messages: `notPaired`, `notSignedIn`, `removedFromLibrary`, `signInTransferFailed`, `libraryKeyMismatch`, `keyGrantFailed`, `unknownDevice`, `deviceOffline(name)`, `nothingPlaying(name)`, `providerUnavailable(ProviderID, deviceName:)`, `playbackFailed`, `commandFailed`, `timedOut`, `needsKey(device:)` (a handoff without the sign-in key on this device, nil, or the named one), `server`, `network`.

What the service seals and opens (`Keys/ContentSealing.swift`): `publish(anchor:queue:)` seals the current track and the window when it sends the window, and sends no content without the key; `fetchQueue(of:)` opens the window (`needsKey` without a key); `send(_:to:)` seals a takeover's window for its target; incoming takeovers are opened before the handler sees them, and one that doesn't open is acked `needsKey` or `unreadable` without running; `ack` sends a failure's `reason` and seals its `message`; `outgoing` results come back with the message opened, or the reason's words (`CommandFailure.message(device:)`); settings are sealed in `putSetting` and opened before `SettingsSync` sees them. When the key this device holds or seals with changes, every row is opened again and `onContentKeyChange` fires (the coordinator publishes its queue again).

### `SyncCoordinator`

The UI-free bridge to `PlayerController`, the same on both platforms.

```swift
init(service: any SyncServicing, player: PlayerController, scheduler: (any PlaybackScheduler)? = nil)
func attach()     // after the providers are registered with the player
func detach()
```

Once attached it does the following:
- It publishes local state when the player reports a change (track, play/pause, seek, queue edit, shuffle/repeat), debounced by 300 ms, and once every 20 s while playing. It publishes nothing while paused.
- It sends the queue window only when the window or the current index changed; other publishes send just the anchor.
- While playing, it takes the position from the engine's live `currentTime`.
- It runs incoming commands against the player and acks them. Volume changes and every other command trigger a publish right away.

Observable state:

| Property | Meaning |
| --- | --- |
| `phase` | `.idle`, `.pulling(from:)` or `.pushing(to:)`. Use it for a spinner on the device row. |
| `lastError: SyncError?` | The last handoff or remote failure, ready to show. |
| `lastHandoff: HandoffReport?` | `kind` (`.pull`/`.push`), `fetchMs`, `readyMs`, `totalMs`, `positionDeltaMs` and `sourcePaused` (the source's ack after a pull). |
| `continueSuggestion: ContinueSuggestion?` | `{ device, playback, isPlaying }`: the other device that is playing (and online), or else the one that paused most recently, under 30 minutes ago. It is nil while this device plays. It is computed when read, so a banner that must disappear after exactly 30 minutes needs a `TimelineView`. |

Actions:

| Method | What it does |
| --- | --- |
| `playHere(from: DeviceID)` | Pull handoff. Throws `nothingPlaying`, `needsKey`, `providerUnavailable`, `playbackFailed`, `timedOut` or `network`. The source keeps playing if it fails. If the requested track can't load here and the player skips to another one, the handoff fails with `playbackFailed` naming the track, and this device pauses (the same for a `takeOver` this device receives). |
| `send(to: DeviceID)` | Push handoff. The target must be online and both devices must hold the key (`needsKey` otherwise). If the target can't play, this throws `commandFailed` with the target's message, for example "Spotify isn't signed in on Riley's iPhone.", and this device keeps playing. |
| `remote(_ device: DeviceID) -> RemoteControl` | `play()`, `pause()`, `toggle()`, `next()`, `previous()`, `stop()`, `seek(to: seconds)` and `setVolume(0…1)`. Each sends a command and returns its `CommandID`. The target's next publish updates `service.playback`. |
| `dismissSuggestion()` | Hides the current suggestion until that device publishes again. |
| `livePosition(of:)`, `effectiveAnchor(_:)` | Position for a device row. A device that went offline while playing counts as paused where it was last seen. |
| `canPlay: (ProviderID) -> Bool` | Decides whether a track's service can play here. The default requires the provider to be registered and signed in. Override it if YouTube Music plays signed out. |

### `SignInSync` (`sync.signIns`)

The apps implement one `SignInTransfer` per provider and register it after the provider has restored its session:

```swift
@MainActor public protocol SignInTransfer: AnyObject {
    var provider: ProviderID { get }
    func exportSignIn() async -> Data?             // the current sign-in, nil when signed out
    func importSignIn(_ data: Data) async throws   // replace this device's sign-in with another device's
    func signOut() async throws                    // sign this device out; throws if the saved sign-in wasn't deleted
    var signInDidChange: (@MainActor () -> Void)? { get set }   // set by SignInSync; call it on every change
}
```

The blob is opaque to MedleySync. YouTube Music exports its cookie and selected channel; Spotify exports its refresh token. The app calls `signInDidChange` after a sign-in, after a token refresh that rotated the stored secret (Spotify), and after a sign-out. Importing usually changes the sign-in too, and calling `signInDidChange` then is fine: an export equal to what was last synced is never uploaded again.

The provider transfers (`YouTubeMusicSignInTransfer`, `SpotifySignInTransfer`) check an incoming sign-in with the service before it replaces anything: YouTube's account menu, Spotify's `/me` on a throwaway client. Only a sign-in the service accepted is committed. If the service refuses it, `importSignIn` throws `rejected`; if it can't be asked (offline, a server error), it throws `unverified`, which is retryable. Either way this device's own session stays as it was. The apps make sure a reconcile comes after the 30 s pause while an import is failing, and again when the app returns to the foreground.

Spotify rotates the refresh token on every refresh, so two devices that refresh the same token at once race, and Spotify refuses the slower one (`invalid_grant`). Before treating that as a revoked session, `SpotifyAPI` asks the transfer for a newer token: first the library's current vault entry (the app sets `SpotifySignInTransfer.syncedSignIn`), then any import that arrives within `refreshRecoveryWait` (6 s). With a newer token the request goes on (refreshing it once if its access token has expired). Without one the session is signed out as before.

| API | What it does |
| --- | --- |
| `register(_ transfer:)` | Starts syncing that provider, and reconciles right away. On the first sync the library's sign-in wins over this device's; a provider the library doesn't have yet is uploaded from here. |
| `signOut(_ provider:, everywhere: Bool)` | Calls `transfer.signOut()`; if that throws, it rethrows and records nothing (no tombstone, not "signed out here"). With `everywhere`, it also writes a tombstone so every device signs out. Without it, this device only ignores that provider's vault updates until it signs in again locally. Show both choices when the user signs out. |
| `status[provider]` | `.unavailable`, `.needsKey`, `.waiting`, `.notSignedIn`, `.synced(serverTime)`, `.signedOutHere`, `.signedOutEverywhere`, `.failed(message)`. |
| `lastImport`, `onImport` | The last sign-in that arrived (`provider`, `updatedAt`, `latencyMs`, `signedOut`, `bytes`). Never the sign-in itself. |

Rules: a vault entry is applied only when its revision is higher than the last one applied here; this device's own writes coming back, and a sign-in equal to what is already here, are not imported. The revision is committed only after `importSignIn` succeeded. If it throws, nothing is marked applied, nothing local is uploaded over that entry, and the same revision is tried again on the next vault update after 30 s. Each device remembers what it last synced (revision, entry time and the SHA-256 of the plaintext) in its credential store, tied to the deployment, library and device id, so restarts don't re-upload and another library starts from nothing. The seal is `AES.GCM` under the library key with the authenticated data `medley.vault.v2:<provider>:<revision>`, the revision the write gets (`baseRevision + 1`). A blob can't be replayed as another provider's, or at another revision. Writes send the revision this device last saw; on `conflict` the device waits for the newer entry. `signOut(_, everywhere: true)` retries once on top of a conflicting write, since the user asked for it.

- **Tombstones** are applied before anything needs the key, so a device still waiting for the key signs out too (status stays `.needsKey`).
- **Failed deletion.** A tombstone or unreadable entry counts as applied only after `transfer.signOut()` returned. If it throws (the Keychain refused to delete the saved sign-in, so the provider stays signed in), the revision stays unapplied and the status is `.failed("…its saved sign-in couldn't be deleted…")`. Because the entry is still newer than what was applied, every reconcile goes back to the sign-out and never reaches the upload, so the credentials still on the device are never sealed back into the vault. The deletion is tried again 30 s later (a timer reconciles), on any vault update after that, at launch, and at once when the app returns to the foreground (`SyncService.setForeground(true)` calls `signIns.retryNow()`). A newer entry from another device supersedes it as usual.
- **Unreadable entries.** An entry that doesn't open at its revision (an old blob put back, or corrupt data) is newer than anything this device applied but wasn't written by a device holding the key. It may cover a sign-out this device missed, so the device signs out of that provider, records the revision, and shows `.failed("…couldn't be opened, so this device signed out of it. Sign in again here to replace it.")`. Nothing is uploaded over it automatically; the next sign-in on this device (an export after it signed out) replaces it at the next revision. Any device token holder could already sign everyone out with `vault:signOutEverywhere`, so this gives a replayer nothing new. A future sealing format must not reuse these rows, or older apps would read it as unreadable and sign out.
- **Legacy entries.** A revision-0 entry with a blob is a v1 seal (`medley.vault.v1:<provider>`, no revision) from before revisions. A device that hasn't applied anything opens it as v1 (only at revision 0), imports it, and migrates it: seals it as v2 for revision 1 and writes it with `baseRevision: 0`. One device's migration wins; the others get `conflict` and read the migrated entry. v1 ciphertext at any later revision is unreadable.
- **Library switches.** `beginSession` keeps the work queue: the new library's sync starts only after an import still running for the old library finished, and every step checks the session before changing the provider or uploading. A sign-in such an import installed (the device already belonged to the new library) is flagged and never uploaded, token refreshes included (`.failed("This sign-in came from the library this device left…")`). Importing the new library's sign-in, or signing out, clears the flag.

### `SettingsSync` (`sync.settings`)

| API | What it does |
| --- | --- |
| `bind(_ settings: PlaybackSettings)` | Syncs `normalizeVolume` (Sound Check), `crossfadeSeconds`, `autoplay` and `sleepTimerMinutes` both ways. `volume` and `outputDeviceUID` stay per device. |
| `observeRecentSearches(current:_:)` | The handler receives the library's recent searches. `current` supplies this device's list for the first sync. When the list changes, call `set(SettingsSync.recentSearchesKey, list)`. |
| `set(_ key:, _ value: Encodable)`, `value(_:as:)`, `observe(_:current:_:)` | Any other synced value. Writes are debounced by 400 ms per key, and an unchanged value is never sent. |

Values from other devices are applied without being sent back. On the first sync the library's value wins; keys the library lacks are filled in from this device with `ifAbsent`, so two devices joining at once don't overwrite each other. Local changes made before the first result arrives are dropped in favour of the library's values. While a write of a key is pending or in flight, values arriving for that key wait; once it settles (or fails), the newest committed value, whoever wrote it, is compared with the local one and adopted when they differ. Two devices writing one key at once therefore both end with the value the server kept.

### Accounts and keys

- `AccountService` (main actor, `@Observable`): the server (`SyncServer.hosted` or `.custom`), its Clerk app from `config:get`, and the Clerk session (`state`: `.loading`, `.signedOut`, `.signedIn(ClerkUser)`). `startEmail` / `verifyEmail`, `startOAuth` / `completeOAuth` (open the URL with the SwiftUI `webAuthenticationSession`, callback scheme `openmusic`), `signOut()`, `checkServer(_:)`, `setServer(_:)`. `tokenProvider` is the `ClerkClient` that `SyncService.signIn` takes.
- `ClerkClient` (actor): Clerk's Frontend API in native mode, `AuthTokenProvider` for the `convex` JWT template. Its state (client token, session, user) lives in the credential store as `sync.credentials.state.clerk` (`CredentialClerkStateStore`).
- `LibraryKey` holds the key and its `id` (fingerprint: the first 16 bytes of SHA-256(`medley.library-key.v1` + key), as hex). `DeviceKeyPair` is the device's X25519 key. `KeyExchange` has the exchange's commitment, `Transcript` (with its `code`) and the grant's `wrap` / `unwrap`; `KeyRotation` wraps a rotated key with the old one. Keys print as `<redacted>`. `KeyLedger` (internal) is each device's record of its exchanges.
- `DeviceInfo.current()` (main actor) returns the name (`Host.localizedName` on macOS, `UIDevice.name` on iOS), the platform, the hardware model (`hw.model`, or the simulator's model identifier) and `CFBundleShortVersionString`.
- `KeychainCredentialStore` keeps the registration (token, device key pair, library key) and the sync state in the Keychain (`MedleyCore.Keychain`, account `sync.credentials` and the `sync.credentials.state.` family). `FileCredentialStore` (0600 JSON) is for the probe, and `MemoryCredentialStore` is for tests and previews. Saved pairings from before accounts don't decode and are dropped.
- `JWTFileTokens` reads a Clerk JWT from a file, for the probe and the apps' Debug self-tests (`-MedleySyncJWTFile`).

## How an app wires sync

Both apps do the same thing. The Mac app wires it in its app model, the iOS app in its `App`.

```swift
let store = KeychainCredentialStore()
let account = AccountService(hostedURL: SyncService.deploymentURL(), store: CredentialClerkStateStore(store: store))
let sync = SyncService(deploymentURL: account.server.url, deviceInfo: .current(), credentials: store)
let coordinator = SyncCoordinator(service: sync, player: player)
// After player.register(youtubeMusic) and player.register(spotify) and their restoreSession():
coordinator.attach()
sync.signIns.register(youTubeMusicSignIn)    // the app's SignInTransfer for each provider
sync.signIns.register(spotifySignIn)
sync.settings.bind(playbackSettings)
sync.settings.observeRecentSearches(current: { model.recentSearches }) { model.replaceRecentSearches($0) }
await account.load()
if let user = account.user, let tokens = account.tokenProvider {
    try await sync.signIn(auth: tokens, userID: user.id)    // registers once, then connects
}

// Scene phase:
.onChange(of: scenePhase) { _, phase in sync.setForeground(phase == .active) }
```

The UI reads:
- Welcome and Settings › Account: `account.state`, `account.socialProviders`, `account.serverProblem`, `account.server`.
- The sign-in key: `sync.keyStatus` (the code and Codes Match / Codes Don't Match while `.comparing`, Ask Again while `.denied` or `.failed`), `sync.keyRequests` (the "Allow <device>…?" alert, with the code), `sync.keyHolders`, `sync.keyWarning`.
- Accounts settings: `sync.signIns.status[.youtubeMusic]` and `[.spotify]` ("Synced", "Signed out on this device only", …).
- Device list: `sync.otherDevices`, with `sync.isOnline(_:)`, `coordinator.livePosition(of:)` and `sync.playback[id]` (track, `anchor.isPlaying`).
- Connection indicator: `sync.connection` (`auth` says whether calls carry the identity).
- Handoff banner and spinners: `coordinator.continueSuggestion`, `coordinator.phase`, `coordinator.lastError`.

The UI calls:
- Sign in: `account.startEmail(email)` then `account.verifyEmail(challenge, code:)`, or `startOAuth` / `completeOAuth`; then `sync.signIn(auth:userID:)`.
- Sign out: `await sync.signOut()`, then `await account.signOut()`. On `sync.onRemoved` and `account.onSessionEnded`, the other half.
- Allow or deny a device: `sync.allowKey(for:)`, `sync.denyKey(for:)`; on the new device: `sync.confirmKeyCode()`, `sync.rejectKeyCode()`, `sync.requestKeyAgain()`.
- Server problems: `account.serverProblem` with a Try Again button (`account.retry()`), `account.notice` after the saved sign-in was dropped for another Clerk host; `account.onReady` connects a saved sign-in once the configuration loads.
- Switch servers: sign out, `account.setServer(url)`, then a new `SyncService` for `account.server.url`.
- Sign out of a service (Accounts): ask "Sign out on this device" or "Sign out on all devices" → `sync.signIns.signOut(.spotify, everywhere: …)`. The transfer's `signOut()` does the local part.
- Device row actions: `coordinator.playHere(from: id)`, `coordinator.send(to: id)`, `coordinator.remote(id).toggle()` and so on, plus `sync.rename(id, to:)` and `sync.remove(id)`.
- "Continue from Mac" banner: `coordinator.playHere(from: suggestion.device.id)`. The close button calls `coordinator.dismissSuggestion()`.

## Client internals

`ConvexClient` (an actor) speaks the Convex WebSocket sync protocol of the npm `convex` 1.49 package (`src/browser/sync/protocol.ts`, `client.ts`, `web_socket_manager.ts`) against `wss://<deployment>/api/1.49.0/sync`.

- **Session.** It sends `Connect` with a fixed `sessionId`, `connectionCount`, `lastCloseReason` and `maxObservedTimestamp`, then `Authenticate` (when a token provider is set; identity version 1), then a `ModifyQuerySet`.
- **Auth.** `setAuth(_:)` takes an `AuthTokenProvider`. The token is refreshed 10 s before it expires (by its `exp - iat` lifetime) and sent with `Authenticate { baseVersion }` on the open socket; a token that went stale while the socket was closed is replaced before it reopens. On `AuthError` the client fetches a fresh token and reconnects; after 3 refusals in a row it runs without an identity (`Status.auth` `.failed`). HTTP calls send `Authorization: Bearer`.
- **Queries.** Query ids are client-chosen, and query set versions count up from 0. Each `Transition` must start at the client's current version (`querySet`, `ts`, `identity`), or the client restarts the socket. `TransitionChunk` messages are reassembled. Server `Ping` messages only reset the 60 s inactivity timer.
- **Mutations.** A mutation resolves once a transition reaches its commit `ts` (read your writes). Failures resolve at once with `errorData` (`ConvexClientError.function`, whose `.code` is `"unauthorized"`, `"notFound"`, …). Every mutation has one lifecycle and one deadline whichever transport carries it: it completes within `Options.mutationTimeout` (30 s), then throws `.transport` and isn't replayed later, so callers such as the coordinator's publish loop never hang; `stop()` fails it with `.stopped`; an answer that arrives after either is dropped.
- **Reconnect.** The client reconnects with jittered backoff of 1 s, doubling to 16 s. On the new socket it replays the whole query set from version 0 and every unanswered or unconfirmed mutation; the server dedupes those by session and request id.
- **HTTP fallback.** After 3 failed connects in a row, queries poll `POST /api/query` every 15 s, only while in the foreground or playing, and mutations use `POST /api/mutation`. Mutations still waiting on the dead socket move to HTTP then: unsent and unanswered ones are sent again (the functions are idempotent, above), and one whose answer arrived but whose commit wasn't observed resolves with that answer. A mutation sent over HTTP stays pending in the client, so its deadline and `stop()` still apply, and it isn't sent on the socket again when one opens. Both send `format: "convex_encoded_json"`. A poll result is delivered unless it equals the last value delivered over either transport, or a socket opened while the poll was in flight (its results are newer). The socket keeps retrying, and the fallback ends when it connects.
- **Suspend.** `suspend()` closes the socket and stops reconnecting but keeps the query set and unanswered mutations; `start()` reconnects and replays both. `SyncService` uses it for the iOS background.
- **Values.** `ConvexValue` encodes Convex JSON. int64 is `{"$integer": base64(8 bytes LE)}`, bytes are `{"$bytes": …}`, and NaN, ±Infinity and −0 are `{"$float": …}`. `Codable` types bridge through `JSONEncoder` and `JSONDecoder`, so numbers are float64, which matches `v.number()`.
- **Clock.** `ServerClock` takes `serverNow` from mutation results. Each sample assumes the server stamped it halfway through the round trip. The estimate uses the fastest of the last 8 samples.

## Platform notes

- iOS kills sockets in the background unless audio is playing. While the iPhone plays it stays connected (or keeps polling on the HTTP fallback) and keeps heartbeating, because `setPlaying(true)` keeps the service active. Paused in the background, it closes the socket itself after 10 s and reconnects when it comes back. When the app is closed, pull handoff from the phone still works: open the app and tap Play here. Pushing to a closed iPhone would need push notifications and an Apple developer team, which we don't have yet.
- Apple's own Handoff (`NSUserActivity`) needs both apps signed by the same team, so it waits until there is a signing identity.

## Testing

- What the server can see: backend cases for plaintext refused everywhere (the old wire shapes, JSON where ciphertext goes, a message in a result, a reason off the list), a wrong or malformed `keyId` refused, an account without a key taking no content, a rotation re-sealing every setting (`conflict` on a missed or changed row, `forbidden` under the old key) while playback under the old key is taken for 10 minutes, a reset deleting settings, and a dump of the content tables holding no title, artist, album, track id or artwork. Swift `ContentSealingTests` (each kind opens only with its kind, account, writer and context; fresh nonces; one key per kind; the authenticated data's layout; cross-language vectors) and `SealedContentServiceTests` (real services through `FakeKeyServer`, which keeps content as the backend does: devices with the key read each other's playback, queue, takeover, result message and recent searches; one without it sees the anchor only, can pause the other device, gets `needsKey` for a handoff and answers a takeover with `needsKey`; after a rotation both remaining devices still read playback and settings; nothing the server holds or was sent contains a title, artist, album, artwork URL, track id, search text or message). C#: the same in `windows/Medley.Sync.Tests/ContentSealingTests.cs`, plus Swift's vectors re-sealed byte for byte and C#'s opened by Swift.
- Live, sealed (2026-11-07, six runs of `scripts/e2e-sync.sh` with `MEDLEY_E2E_HOLD=1`, a `+clerk_test` user of its own; three before the review fixes, three after, with the iPhone app rebuilt for the last; the fifth lost only its probe step, to a test JWT that had expired): before the iPhone had the key it showed `REMOTE-STATE Mac: playing "(sealed)"`, a banner without a title and "This device doesn't have your sign-in key yet…" on Play Here, and paused the Mac remotely; with the key, Play Here and send back with real YouTube streams, remote pause and play, recent searches, a sign-in through the vault; a third device (medley-probe) took the key and was removed, the key rotated, and both apps read each other's titles and handed off. A dump of every table while the account still had its rows (`npx convex export`) held none of the titles, artists, album, track ids, artwork hosts or searches played, only fingerprints, anchors and sealed blobs; the only URLs were the Clerk issuer in `owner`. `windows/scripts/live-cross-platform.sh` (C# and Swift probes): the C# device showed the Swift device's playback as "(sealed)" until it had the key, then pulled and pushed playback and sent remote commands.
- Backend: 78 `convex-test` cases in `sync/convex/sync.test.ts` with mocked identities (`t.withIdentity`): config with and without the key, every function needing an identity, registration (idempotent per token, one library per user, other users isolated, 32-device eviction, the per-user limit), the first device's key and the two-first-devices race, the exchange and its refusals, the fingerprint making no device a holder, rotation, the reset keeping revisions, legacy rows swept in bounded runs and their tokens refused, expiry, publish, commands, the vault (revisions, compare and swap, idempotent retries, an old blob can't undo a sign-out, key fingerprint check, ciphertext-only rows, the legacy v1 migration) and settings (`writeId`, a late retry after another device's write, `ifAbsent`).
- Swift: `swift test --filter MedleySyncTests` (184 cases; 906 in the whole package): value encoding, the protocol state machine against a fake transport (subscribe, transitions, mutation ordering, reconnect replay, chunking, inactivity, HTTP fallback), authentication (Authenticate before the query set on every socket, refresh before expiry, AuthError recovery and giving up, the HTTP Bearer header) with a fake token provider, the key exchange's crypto, the exchange between real `SyncService`s through an in-memory key server that can misbehave (`FakeKeyServer`, `KeyExchangeServiceTests`), `ClerkClient` against a fake Frontend API (email sign-in and sign-up, native mode headers, client token rotation, the token cache, an ended session, OAuth with a nonce and with a transfer, social providers, sign-out, host checks, origin binding, sign-out winning a race), `AccountService` (server URLs, `config:get`, offline launch and its retries, the origin notice), registration through `SyncService`, plus the sign-in and settings sync (including after a key reset), coordinator and lifecycle cases from before.
- Live: `medley-probe sync …` needs `--jwt-file` with a Clerk session JWT (template `convex`) for a test user. `scripts/e2e-sync.sh` is the live accounts check of both apps against dev and the real Clerk instance (`docs/accounts-design.md`, Testing). `scripts/mac-sync-live.sh` and `scripts/ios-sync-live.sh` still drive invite pairing and stop with a message until they are reworked for accounts.

```bash
P=.build/debug/medley-probe; L=~/agents/openmusic-sync-live; J=$L/jwt.txt   # a Clerk session JWT for the test user
$P sync sign-in --name "Probe Mac A" --state $L/a.json --jwt-file $J     # the first device: holds the sign-in key
$P sync sign-in --name "Probe Phone B" --state $L/b.json --jwt-file $J   # asks for it
# The exchange in one go, both devices running as two apps would (each short command below acts one process late):
$P sync run --state $L/a.json --jwt-file $J --script "allow-key 45; sleep 5; quit" &   # REQUEST … code, ALLOWED
$P sync run --state $L/b.json --jwt-file $J --script "confirm-key 45; quit"             # CODE …, then the key
# Or step by step:
$P sync keys --state $L/a.json --jwt-file $J                             # A answers B's commitment
$P sync keys --state $L/b.json --jwt-file $J                             # B reveals; shows comparing(code: "482 913" …)
$P sync keys --state $L/a.json --jwt-file $J                             # REQUEST Probe Phone B … code 482 913
$P sync allow all --state $L/a.json --jwt-file $J
$P sync confirm --state $L/b.json --jwt-file $J                          # the codes match: B takes the key
$P sync fake-play --name "Probe Mac A" --state $L/a.json --jwt-file $J --seconds 60 &
$P sync run --name "Probe Phone B" --state $L/b.json --jwt-file $J --script \
  "sleep 3; play-here <A id>; sleep 8; send <A id>; sleep 5; remote <A id> toggle; quit"
```
