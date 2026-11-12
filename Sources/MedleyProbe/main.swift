import Foundation
import MedleyCore

// medley-probe <provider> <command> [args...]
// Exercises providers from the command line so they can be verified over SSH without the UI.
// Each provider registers its commands in its own file (YouTubeMusicProbe.swift, SpotifyProbe.swift).

@MainActor
func runProbe() async -> Int32 {
    var args = Array(CommandLine.arguments.dropFirst())
    guard let provider = args.first else {
        print("usage: medley-probe <ytm|spotify|sync> <command> [args...]")
        return 2
    }
    args.removeFirst()
    do {
        switch provider {
        case "ytm": return try await YouTubeMusicProbe.run(args)
        case "spotify": return try await SpotifyProbe.run(args)
        case "sync": return try await SyncProbe.run(args)
        default:
            print("unknown provider \(provider)")
            return 2
        }
    } catch {
        print("error: \(error.localizedDescription)")
        return 1
    }
}

let code = await runProbe()
exit(code)
