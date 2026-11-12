# OpenMusic.Sync

The Windows app's sync client: the same OpenMusic account as the Mac and iPhone apps. A C# port of `Sources/OpenMusicSync` (accounts branch); `docs/accounts-design.md` and `docs/sync-design.md` are the contract, and `sync/convex/*.ts` is the source of truth for every function, argument and error. net10.0 with no Windows dependency, so it builds and tests on Linux.

## What the app uses

| Type | Role |
| --- | --- |
| `AccountService` | Server choice (hosted or one custom URL), the server's Clerk app (`config:get`), email-code and OAuth sign-in, sign-in generations, `StartSyncAsync(sync)`, `SignOutAsync(sync)`. Events: `SessionEnded` (then `EndedSignIn`), `Ready`. |
| `ClerkClient` | Clerk's Frontend API in native mode; also the Convex `IAuthTokenProvider` (`convex` JWT template, refreshed before expiry). |
| `SyncService` | Registration, devices, playback, commands, the vault key exchange (Allow, Codes Match, Ask Again), rotation, claims, removal and sign-out. `INotifyPropertyChanged`; events `Removed`, `CommandReceived`. |
| `SignInSync` (`SyncService.SignIns`) | YouTube Music and Spotify sign-ins, end-to-end encrypted. Register an `ISignInTransfer` per provider. |
| `SettingsSync` (`SyncService.Settings`) | Synced settings (`SettingKeys`) and recent searches, last write wins. |
| `SyncCoordinator` | Publishes local playback, runs incoming commands, `PlayHereAsync` (pull), `SendToAsync` (push), `Remote(device)`. Drives an `ISyncPlayer`; `PlayerControllerAdapter` wraps OpenMusic.Core's `PlayerController`. |
| `ISecretStore` | Where secrets live. Implement it with DPAPI in the app; `FileSecretStore` (0600 files) and `MemorySecretStore` are for Linux tools and tests. |

Sign-in, then sync:

```csharp
var actor = new SyncActor(SynchronizationContext.Current!);   // the UI thread's context
var store = new SyncCredentialStore(new DpapiSecretStore());   // the app's ISecretStore
var account = new AccountService(hostedUrl, new CredentialClerkStateStore(store), actor, preferences);
var sync = new SyncService(account.Server.Url, deviceInfo, store, actor);
await account.LoadAsync();
var challenge = await account.StartEmailAsync(email);
var user = await account.VerifyEmailAsync(challenge, code);
await account.StartSyncAsync(sync);   // sync for the sign-in shown, decided and started in one step on the actor
// Later: await account.SignOutAsync(sync);
```

OAuth: `StartOAuthAsync(ClerkOAuthProvider.Google)` returns a URL to open in the system browser; the app registers the `openmusic:` URL scheme and passes the `openmusic://oauth-callback?...` activation to `CompleteOAuthAsync`.

## Threading

All state lives on one `SyncActor` (the stand-in for the Swift client's `@MainActor`). Every public method dispatches to it before it reads or changes state: async methods `await actor.Switch()`, methods that return nothing go through `actor.Perform` (inline on the actor, posted from elsewhere), synchronous reads through `actor.Read` (inline on the actor, `Send` from elsewhere). Published properties are immutable snapshots replaced on the actor, so reading one from another thread sees one whole value. `PropertyChanged` and the events are raised on the actor. The code that touches state calls `actor.AssertCurrent()`, which throws in debug builds when it runs anywhere else (`SyncActor.Violations` counts them; the tests assert it stays 0). `ClerkClient` and `ConvexClient` serve the socket's threads, so their serialization point is their lock instead: every public method takes it, and state changes assert it is held. Give the app's UI `SynchronizationContext` to the actor and everything, the `PlayerController` included, runs on the UI thread with no marshalling; `SyncActor.CreateDedicated()` gives a background thread instead (then marshal events yourself). Network and crypto never block it.

`AccountOperations` runs every account and key operation one at a time, with epochs: a sign-in, sign-out, forget or stop cancels and abandons older operations, and a sign-out is never cancelled. This is what removes the interleaving bugs the Swift review rounds found.

## Identity tickets

Every operation that can await captures who it is for when it is created, on the actor, before its first await, and every effect checks that it still is, right before it happens, with nothing awaited between the check and the effect (under the lock in the two clients). Work whose ticket went stale is dropped (`SyncErrorKind.AuthChanged`, `ClerkErrorKind.Stale`, `ConvexErrorKind.AuthChanged` or `OperationCanceledException`).

| Ticket | Captured by | Checked before |
| --- | --- | --- |
| Server epoch, account epoch, sign-in generation, Clerk instance (`AccountService`) | every public method | making and installing a Clerk client (server epoch only; a switch retires the old client before its first await, and a retired client never writes the store), showing a completed sign-in (no sign-out or server switch since, and Clerk still holds exactly that session), publishing a refresh |
| Session generation and the flow's client token (`ClerkClient`) | each flow, request and token fetch | adopting a session, keeping a client token, caching a token, ending a session; a stale sign-in ends the session it made at Clerk with its own client token, and a new sign-in ends the one it replaces |
| Identity scope (`ConvexClient`) | `SetAuthAsync`, passed to every call, query and subscription | enqueuing and sending a call, delivering a query result, returning a one-shot result; queries of an old scope are failed and taken out of the query set when it changes |
| Device token, scope, epoch, session (`SyncService`, public as `SyncIdentity`) | every call, live query and incoming command | returning an answer, applying a live query result, acking a command, returning a fetched queue or list; a stopped service stays stopped until `Start` or a sign-in |
| Registration session (`SignInSync`, `SettingsSync`) | each provider sign-out, reconcile and upload | each local deletion, import, vault write, setting write and status change |
| `SyncIdentity` (`SyncCoordinator`) | each handoff, publish round and incoming command | loading the player, pausing the source, recording the result |

A server switch, a sign-out and a sign-in bump the epochs and generations above and cancel what is in flight for the old ones.

## Crypto

X25519 is BouncyCastle's managed RFC 7748 code (`BouncyCastle.Cryptography`, the only package), behind `IX25519`. It runs the same on Windows x64 and ARM64 and on Linux, so the Linux tests exercise what ships; .NET has no portable X25519 (CNG's curve25519 is Windows-only and its key import doesn't take raw keys), and NSec would add a native libsodium. SHA-256, HMAC, HKDF and AES-GCM are .NET's own. Private keys are kept as raw bytes and clamped only when used, as CryptoKit does (BoringSSL deliberately stores them unclamped).

`tests/OpenMusic.Sync.Tests/Vectors/swift-vectors.json` was made by the Swift code (`windows/scripts/swift-vectors.sh <accounts checkout>` runs `CSharpVectorTests.swift.txt` on the build Mac, copied into a scratch checkout there). `CrossLanguageVectorTests` reproduces every derivation and opens every Swift blob; the same script with a C# vectors file (`OPENMUSIC_CSHARP_VECTORS_OUT=… dotnet test --filter WriteCSharpVectors`) has the Swift code open what C# sealed.

## Sealed content

What plays, queues, takeovers, command messages and settings reach the server only sealed with the vault key (`Keys/ContentSealing.cs`, byte-compatible with `Sources/OpenMusicSync/Keys/ContentSealing.swift`; `docs/sync-design.md`, "What the server can see"). `SyncService` seals what it publishes, sends, acks and writes and opens what it reads, again whenever its key changes (`ContentKeyChanged`, which the coordinator answers by publishing its queue again). Without the key a device publishes its anchor alone, shows others' playback with `Track` null ("Playing on Riley's Mac · 2:13"), can still send and ack remote commands, and gets `SyncErrorKind.NeedsKey` for a handoff; `CanSealContent` says which. `Vectors/swift-content-vectors.json` comes from the Swift tests (`OPENMUSIC_CONTENT_VECTORS_OUT=<path> swift test --filter ContentSealingTests` on the build Mac) and is re-sealed byte for byte by `ContentSealingTests`; `OPENMUSIC_CSHARP_CONTENT_VECTORS_OUT=<path> dotnet test --filter WriteCSharpContentVectors` writes the C# side for the Swift test `csharpVectorsOpen` (`OPENMUSIC_CSHARP_CONTENT_VECTORS=<path>`).

## Known differences from the Swift apps

- None for platforms any more: a Windows device registers as `windows` (`SyncService.SendsWindowsPlatform`, on), which the backend takes and the Swift apps decode; every client reads a platform it doesn't know as unknown.
- `ConvexClient` also supports actions (`ActionAsync`), which the Swift client doesn't use. An action is never replayed.

## Running

```bash
~/.dotnet/dotnet test windows/tests/OpenMusic.Sync.Tests          # unit, service, race and vector tests (Linux)
windows/scripts/live-two-csharp.sh                        # two C# probe devices on the dev deployment
dotnet windows/src/OpenMusic.SyncProbe/bin/Debug/net10.0/OpenMusic.SyncProbe.dll run --state <dir> --name A --play --script "..."
```
