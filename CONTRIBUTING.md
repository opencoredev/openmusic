# Contributing to OpenMusic

Thanks for helping. This page gets you from a fresh clone to a build and a passing test run on each platform, and lists what to check before you open a pull request. Everything here runs on your own machine; nothing needs the maintainers' build machines or accounts.

## Repository map

| Path | What it holds |
| --- | --- |
| `Package.swift` | The Swift package: the Mac app, the shared libraries the iPhone app links, and their tests. macOS 15+, iOS 26+. |
| `Sources/OpenMusic/` | The Mac app (SwiftUI, AppKit where SwiftUI falls short). |
| `Sources/OpenMusicCore/` | Shared models, the `MusicProvider` and `PlaybackEngine` contracts, the player (queue, shuffle, repeat, autoplay), system integration (Now Playing, media keys), Keychain access, and `MockProvider` with sample data. |
| `Sources/YouTubeMusicKit/` | YouTube Music: the InnerTube API, Google sign-in, stream resolution. |
| `Sources/SpotifyKit/` | Spotify: Web API, OAuth with PKCE, playback through the Spotify app or Spotify Connect. |
| `Sources/OpenMusicSync/` | The sync client: Convex WebSocket client, Clerk sign-in, device keys, playback handoff, settings and sign-in sync. |
| `Sources/OpenMusicProbe/` | `openmusic-probe`, a command-line tool that exercises the providers and sync. |
| `Resources/` | The Mac app's Info.plist, entitlements, icon, and the Keychain XPC service (`KeychainService/`). |
| `Tests/` | Swift Testing suites, one folder per target. Provider tests run against saved JSON fixtures. |
| `iOS/` | The iPhone app: its sources and the XcodeGen spec `project.yml`. See [iOS/README.md](iOS/README.md). |
| `windows/` | The Windows app (WinUI 3, .NET 10) and `OpenMusic.Core`, a cross-platform C# port of the shared logic. See [windows/README.md](windows/README.md). |
| `sync/` | The sync backend (`sync/convex/`, TypeScript on Convex) and the self-hosting setup (`sync/self-host/`). |
| `scripts/` | Build and packaging scripts (`bundle.sh`, `signing-identity.sh`, `package-windows.sh`), screenshot and test drivers, and the maintainers' remote-machine helpers ([docs/maintainers.md](docs/maintainers.md)). |
| `docs/` | User guides and design documents. [docs/README.md](docs/README.md) lists them. |

[AGENTS.md](AGENTS.md) is written for coding agents: the architecture, invariants and rules a change must keep. It is worth reading before a larger change, but you don't need it to build or test.

## Mac

Needs a Mac with Apple silicon, macOS 15 or later to run the app, and Xcode 27 or later (Swift 6.4) to build. The package has no third-party dependencies.

```bash
git clone https://github.com/opencoredev/openmusic.git
cd openmusic
swift build                  # every target
swift test                   # about 920 tests, a few minutes
scripts/bundle.sh            # build/OpenMusic.app (release)
open build/OpenMusic.app
```

`CONFIG=debug scripts/bundle.sh` builds a debug app instead. To run the app on made-up sample data with no network: `open --env OPENMUSIC_MOCK=1 build/OpenMusic.app`.

### Staying signed in across rebuilds

macOS lets a Keychain item be read only by the code that saved it. Without a stable signing identity, `scripts/bundle.sh` signs the app ad-hoc, every build has a different code signature, and each new build can't read the sign-ins the previous one saved: it starts signed out of YouTube Music, Spotify and sync every time. It prints a warning when that happens.

To avoid it, create a local self-signed identity once:

```bash
scripts/signing-identity.sh
```

It makes a code-signing certificate in a keychain of its own under `~/agents/medley-signing/` (not your login keychain), with a random password kept in a file there (mode 600). It is safe to run again. From then on `scripts/bundle.sh` signs with it and embeds the Keychain XPC service (`Resources/KeychainService/`), and sign-ins saved by one build stay readable by the next. The folder and certificate names keep the project's old name on purpose: renaming them would sign everyone out.

## iPhone

Needs the Mac setup above plus [XcodeGen](https://github.com/yonaskolb/XcodeGen) and an Apple ID; a free one works.

```bash
brew install xcodegen
xcodegen generate --spec iOS/project.yml
open iOS/OpenMusic.xcodeproj
```

The project is set to build for the Simulator without a team. To run on your iPhone, follow [Install on your iPhone](iOS/README.md#install-on-your-iphone): choose your team under **Signing & Capabilities** and change the bundle identifier if Xcode says it is taken. The iPhone app shares its logic with the package, so `swift test` covers most of it.

## Windows

The Windows app builds on Windows 10 2004 or later, or Windows 11, with the [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0). Nothing else: the Windows App SDK comes from NuGet and is bundled with the app, and Visual Studio isn't needed. Run these from the `windows` folder:

```powershell
cd windows
dotnet build src\OpenMusic.App\OpenMusic.App.csproj -c Debug -p:Platform=x64
.\src\OpenMusic.App\bin\x64\Debug\net10.0-windows10.0.22621.0\win-x64\OpenMusic.exe --demo --dataset sample
dotnet publish src\OpenMusic.App\OpenMusic.App.csproj -c Release -r win-x64 -p:Platform=x64 -o publish
```

`--demo --dataset sample` runs on made-up sample data with no network; without it the app is live. Google sign-in needs the WebView2 runtime, which Windows 11 has. [windows/README.md](windows/README.md) lists the app's options, snapshots and ARM64 builds.

The shared C# code (`OpenMusic.Core`, the YouTube provider and the sync client) builds and tests on any OS with the .NET 10 SDK, Linux and macOS included. From the repository root:

```bash
dotnet test windows/OpenMusic.Core.slnf
```

Use the `.slnf`: `OpenMusic.sln` also holds the app, whose XAML compiler runs only on Windows.

## Sync backend

Needs Node.js 22.12 or newer (22 LTS or 24 LTS); the Convex CLI and the test runner in the lockfile require it. The tests run against an in-memory backend, so no Convex account or server is needed.

```bash
cd sync
npm ci
npm run typecheck
npx vitest run --maxWorkers=4
```

To run a server of your own, see [self-hosting](docs/self-hosting.md).

## Before you open a pull request

Run the checks for what you changed:

| You changed | Run |
| --- | --- |
| Swift (`Sources/`, `Tests/`, `iOS/`) | `swift build` and `swift test`; for iPhone UI, build the iOS app in Xcode |
| C# (`windows/`) | `dotnet test windows/OpenMusic.Core.slnf`; for the app, build it on Windows and run it |
| Backend (`sync/convex/`) | `npm run typecheck` and `npx vitest run --maxWorkers=4` in `sync/` |
| Docs | Check that links resolve and commands work as written |

CI runs the same checks on every pull request: the C# core and sync tests and a secrets scan on Linux, `swift build` and `swift test` on macOS, and a Release build of the Windows app. For UI changes, attach screenshots in light and dark.

Never commit tokens, cookies, keys or personal data, in code, fixtures, logs or screenshots. CI's gitleaks scan (configured in `.gitleaks.toml`) fails on anything that looks like a secret; if it flags a value that is public by design, add the narrowest allowlist entry you can and say why in the pull request.

## Code style

- **Swift:** Swift 6 with strict concurrency; the app targets are main-actor isolated by default. Network and JSON parsing stay off the main actor. No third-party dependencies in the Apple apps: Apple frameworks only.
- **C#:** follows `windows/Directory.Build.props` (nullable on, nullable warnings are errors). The C# core mirrors the Swift sources file for file; when you change a Swift model or the player, port the change and its tests ([windows/AGENTS.md](windows/AGENTS.md) has the porting rules).
- **Behavior:** an operation a service doesn't support throws `ProviderError.notSupported` and its `capabilities` say so, so the UI can hide it. No polling timers while paused. Never log tokens, cookies or account data.
- **User-facing text** uses the product name through `ProductInfo` (Swift and C#), never spelled out.
- **Docs and comments:** plain and specific. Say what the code does and why, not what it used to do.

## Questions and bugs

Open an [issue](https://github.com/opencoredev/openmusic/issues/new/choose). Security problems go through [private reporting](SECURITY.md). Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).
