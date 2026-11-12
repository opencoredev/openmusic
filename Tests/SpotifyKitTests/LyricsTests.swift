import Foundation
import MedleyCore
import Testing

@Suite struct LRCParsingTests {
    @Test func parsesTimestampFormats() {
        let lines = LRCLibClient.parseLRC(Fixture.text("sample", ext: "lrc"))
        #expect(lines.map(\.text) == [
            "Like the legend of the phoenix, huh",
            "All ends with beginnings",
            "Colon hundredths form",
            "No fraction",
            "",
            "We're up all night to get lucky",
            "We're up all night to get lucky",
        ])
        let times = lines.compactMap(\.time)
        #expect(times.count == lines.count)
        #expect(abs(times[0] - 31.48) < 0.001)
        #expect(abs(times[2] - 40.12) < 0.001)   // [00:40:12]
        #expect(times[3] == 45)                   // [00:45]
        #expect(abs(times[5] - 62.5) < 0.001)     // [01:02.5]
        #expect(abs(times[6] - 130.25) < 0.001)   // [02:10.250], second stamp on the same line
        #expect(times == times.sorted())
    }

    @Test func appliesOffset() {
        let lines = LRCLibClient.parseLRC("[offset:+500]\n[00:10.00]a\n[00:00.20]b")
        #expect(lines.map(\.text) == ["b", "a"])
        #expect(lines.map(\.time) == [0, 9.5]) // shifted earlier, clamped at 0
    }

    @Test func ignoresMetadataAndJunk() {
        #expect(LRCLibClient.parseLRC("[ar:Someone]\n[ti:Song]\nplain text\n[99:99.99] bad").isEmpty)
    }
}

@Suite struct LRCLibClientTests {
    final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var urls: [URL] = []
        func add(_ url: URL) { lock.withLock { urls.append(url) } }
        var all: [URL] { lock.withLock { urls } }
    }

    @Test func getThenSearchFallback() async throws {
        let recorder = Recorder()
        let client = LRCLibClient { request in
            recorder.add(request.url!)
            #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("OpenMusic/") == true)
            if request.url!.path == "/api/get" { return (404, Data(#"{"code":404,"name":"TrackNotFound"}"#.utf8)) }
            return (200, Fixture.data("lrclib-search"))
        }
        let lyrics = try #require(try await client.lyrics(title: "Get Lucky", artist: "Daft Punk", album: "Random Access Memories", duration: 369.6))
        #expect(lyrics.isSynced)
        #expect(lyrics.source == "LRCLIB")
        #expect(lyrics.lines.first?.text == "Like the legend of the phoenix, huh") // record 103: close duration and synced
        let urls = recorder.all
        #expect(urls.map(\.path) == ["/api/get", "/api/search"])
        let get = URLComponents(url: urls[0], resolvingAgainstBaseURL: false)!.queryItems!
        #expect(get.first { $0.name == "duration" }?.value == "370")
        #expect(get.first { $0.name == "album_name" }?.value == "Random Access Memories")
    }

    @Test func skipsGetWithoutAlbumOrDuration() async throws {
        let recorder = Recorder()
        let client = LRCLibClient { request in
            recorder.add(request.url!)
            return (200, Fixture.data("lrclib-search"))
        }
        _ = try await client.lyrics(title: "Get Lucky", artist: "Daft Punk")
        #expect(recorder.all.map(\.path) == ["/api/search"])
    }

    @Test func bestMatchPrefersCloseDurationThenSynced() throws {
        let records = try JSONDecoder().decode([LRCLibClient.Record].self, from: Fixture.data("lrclib-search"))
        #expect(LRCLibClient.bestMatch(in: records, duration: 369)?.id == 103)
        #expect(LRCLibClient.bestMatch(in: records, duration: 248)?.id == 101)
        #expect(LRCLibClient.bestMatch(in: records, duration: nil)?.syncedLyrics?.isEmpty == false)
        #expect(LRCLibClient.bestMatch(in: records, duration: 30) == nil) // nothing within 10 s
    }

    @Test func plainAndInstrumental() {
        let plain = LRCLibClient.Record(id: 1, plainLyrics: "one\ntwo", syncedLyrics: nil)
        #expect(LRCLibClient.lyrics(from: plain)?.lines == [LyricLine(text: "one"), LyricLine(text: "two")])
        #expect(LRCLibClient.lyrics(from: plain)?.isSynced == false)
        let instrumental = LRCLibClient.Record(id: 2, instrumental: true)
        #expect(LRCLibClient.lyrics(from: instrumental)?.lines.first?.text == "Instrumental")
        #expect(LRCLibClient.lyrics(from: LRCLibClient.Record(id: 3)) == nil)
    }

    @Test func rateLimitIsReported() async {
        let client = LRCLibClient { _ in (429, Data()) }
        await #expect(throws: ProviderError.rateLimited) { try await client.lyrics(title: "x", artist: "y") }
    }
}
