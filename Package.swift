// swift-tools-version: 6.2
import PackageDescription

// Medley: a native macOS player for YouTube Music and Spotify.
// No third-party dependencies. Everything is built on Apple frameworks.

let mainActorByDefault: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
]

let package = Package(
    name: "Medley",
    platforms: [.macOS(.v15), .iOS("26.0")],
    products: [
        .executable(name: "Medley", targets: ["Medley"]),
        .executable(name: "medley-probe", targets: ["MedleyProbe"]),
        // Libraries for the iOS app (iOS/project.yml links these from the local package).
        .library(name: "MedleyCore", targets: ["MedleyCore"]),
        .library(name: "YouTubeMusicKit", targets: ["YouTubeMusicKit"]),
        .library(name: "SpotifyKit", targets: ["SpotifyKit"]),
        .library(name: "MedleySync", targets: ["MedleySync"]),
    ],
    targets: [
        // Shared models, the provider contract, playback queue and engines.
        .target(name: "MedleyCore"),

        // YouTube Music via the InnerTube API (the same API music.youtube.com uses).
        .target(name: "YouTubeMusicKit", dependencies: ["MedleyCore"]),

        // Spotify via the Web API (OAuth PKCE) with Spotify Connect / Spotify.app playback.
        .target(name: "SpotifyKit", dependencies: ["MedleyCore"]),

        // Cross-device sync over Convex (sync/convex): pairing, presence, playback state, handoff, remote commands.
        .target(name: "MedleySync", dependencies: ["MedleyCore"]),

        // The SwiftUI app.
        .executableTarget(
            name: "Medley",
            dependencies: ["MedleyCore", "YouTubeMusicKit", "SpotifyKit", "MedleySync"],
            swiftSettings: mainActorByDefault
        ),

        // Command-line probe for exercising providers without the UI (used for live verification).
        .executableTarget(
            name: "MedleyProbe",
            dependencies: ["MedleyCore", "YouTubeMusicKit", "SpotifyKit", "MedleySync"]
        ),

        .testTarget(name: "MedleyCoreTests", dependencies: ["MedleyCore"]),
        // App model behavior (search navigation, results, recent searches) against the mock providers.
        .testTarget(name: "MedleyTests", dependencies: ["Medley", "MedleyCore"]),
        .testTarget(name: "YouTubeMusicKitTests", dependencies: ["YouTubeMusicKit"], resources: [.copy("Fixtures")]),
        .testTarget(name: "MedleySyncTests", dependencies: ["MedleySync", "MedleyCore"]),
        .testTarget(name: "SpotifyKitTests", dependencies: ["SpotifyKit"], resources: [.copy("Fixtures")]),
    ]
)
