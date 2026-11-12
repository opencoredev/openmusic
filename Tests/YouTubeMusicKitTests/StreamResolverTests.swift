import Foundation
import OpenMusicCore
import Testing
@testable import YouTubeMusicKit

/// Cache policy of `YouTubeStreamResolver`, with the InnerTube lookup replaced by a counter.
@Suite struct StreamResolverCache {
    let track = Track(providerID: "FGBhQbmPwH8", provider: .youtubeMusic, title: "Test")

    func makeResolver(validFor seconds: TimeInterval = 6 * 3600) -> YouTubeStreamResolver {
        YouTubeStreamResolver(client: InnerTubeClient()) { videoId in
            let url = URL(string: "https://example.invalid/\(videoId)/\(UUID().uuidString)")!
            let stream = PlayableStream(url: url, expiresAt: Date().addingTimeInterval(seconds))
            return .init(stream: stream, client: "TEST", itag: 234)
        }
    }

    @Test func reusesAnUnexpiredStream() async throws {
        let resolver = makeResolver()
        let a = try await resolver.resolveStream(for: track)
        let b = try await resolver.resolveStream(for: track)
        #expect(a == b)
        #expect(await resolver.fetchCount == 1)
    }

    @Test func forceRefreshSkipsTheCacheAndReplacesIt() async throws {
        let resolver = makeResolver()
        // Through the protocol, the way `AVPlaybackEngine` calls it during recovery.
        let generic: any StreamResolver = resolver
        let cached = try await generic.resolveStream(for: track)
        let fresh = try await generic.resolveStream(for: track, forceRefresh: true)
        #expect(fresh != cached)
        #expect(await resolver.fetchCount == 2)
        #expect(try await generic.resolveStream(for: track) == fresh)
        #expect(await resolver.fetchCount == 2)
    }

    @Test func refetchesWhenLittleValidityIsLeft() async throws {
        let resolver = makeResolver(validFor: 300)
        let a = try await resolver.resolveStream(for: track)
        let b = try await resolver.resolveStream(for: track)
        #expect(a != b)
        #expect(await resolver.fetchCount == 2)
    }
}
