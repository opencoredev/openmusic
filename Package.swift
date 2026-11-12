// swift-tools-version: 6.2
import PackageDescription

// OpenMusic: a native macOS player for YouTube Music and Spotify.
// No third-party dependencies. Everything is built on Apple frameworks.

let mainActorByDefault: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
]

let package = Package(
    name: "OpenMusic",
    platforms: [.macOS(.v15), .iOS("26.0")],
    products: [
        .executable(name: "OpenMusic", targets: ["OpenMusic"]),
        .executable(name: "openmusic-probe", targets: ["OpenMusicProbe"]),
        // Libraries for the iOS app (iOS/project.yml links these from the local package).
        .library(name: "OpenMusicCore", targets: ["OpenMusicCore"]),
        .library(name: "YouTubeMusicKit", targets: ["YouTubeMusicKit"]),
        .library(name: "SpotifyKit", targets: ["SpotifyKit"]),
        .library(name: "OpenMusicSync", targets: ["OpenMusicSync"]),
    ],
    targets: [
        // Shared models, the provider contract, playback queue and engines.
        .target(name: "OpenMusicCore"),

        // YouTube Music via the InnerTube API (the same API music.youtube.com uses).
        .target(name: "YouTubeMusicKit", dependencies: ["OpenMusicCore"]),

        // Spotify via the Web API (OAuth PKCE) with Spotify Connect / Spotify.app playback.
        .target(name: "SpotifyKit", dependencies: ["OpenMusicCore"]),

        // Cross-device sync over Convex (sync/convex): pairing, presence, playback state, handoff, remote commands.
        .target(name: "OpenMusicSync", dependencies: ["OpenMusicCore"]),

        // The SwiftUI app.
        .executableTarget(
            name: "OpenMusic",
            dependencies: ["OpenMusicCore", "YouTubeMusicKit", "SpotifyKit", "OpenMusicSync"],
            swiftSettings: mainActorByDefault
        ),

        // Command-line probe for exercising providers without the UI (used for live verification).
        .executableTarget(
            name: "OpenMusicProbe",
            dependencies: ["OpenMusicCore", "YouTubeMusicKit", "SpotifyKit", "OpenMusicSync"]
        ),

        .testTarget(name: "OpenMusicCoreTests", dependencies: ["OpenMusicCore"]),
        // App model behavior (search navigation, results, recent searches) against the mock providers.
        .testTarget(name: "OpenMusicTests", dependencies: ["OpenMusic", "OpenMusicCore"]),
        .testTarget(name: "YouTubeMusicKitTests", dependencies: ["YouTubeMusicKit"], resources: [.copy("Fixtures")]),
        .testTarget(name: "OpenMusicSyncTests", dependencies: ["OpenMusicSync", "OpenMusicCore"]),
        .testTarget(name: "SpotifyKitTests", dependencies: ["SpotifyKit"], resources: [.copy("Fixtures")]),
    ]
)
