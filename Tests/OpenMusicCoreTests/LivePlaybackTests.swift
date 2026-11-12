import Darwin
import Foundation
import Testing
@testable import OpenMusicCore

/// Network test against Apple's public HLS sample (audio-only AAC rendition). Opt-in:
///   OPENMUSIC_LIVE=1 swift test --filter LivePlaybackTests
@MainActor
@Suite(.serialized, .enabled(if: LaunchEnvironment.current["OPENMUSIC_LIVE"] == "1"))
struct LivePlaybackTests {
    static let base = "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/gear0"
    let stream = URL(string: "\(base)/prog_index.m3u8")!
    /// Same media, different URL: what a fresh YouTube signature looks like to AVPlayer.
    let refreshed = URL(string: "\(base)/prog_index.m3u8?openmusic-refresh=1")!
    let broken = URL(string: "\(base)/expired-\(UUID().uuidString).m3u8")!

    func log(_ message: String) {
        print("[live] \(message)")
    }

    @Test func playsRecoversAndIdlesAtZeroCPU() async throws {
        let resolver = FakeResolver(urls: [broken, stream, refreshed])
        let engine = AVPlaybackEngine(resolver: resolver)
        let events = EventLog()
        events.attach(to: engine)
        let track = Track(providerID: "bipbop", provider: .youtubeMusic, title: "BipBop")

        // 1. The first URL is dead (real HTTP error from the CDN). The engine re-resolves and plays.
        try await engine.load(track, startAt: 0, autoplay: true)
        #expect(await waitUntil(timeout: 20) { events.lastState == .playing })
        log("state=\(events.lastState.map { "\($0)" } ?? "nil") after dead first URL; resolves=\(resolver.calls) recoveries=\(engine.recoveryCount)")
        #expect(resolver.calls == 2)

        // 2. Time advances.
        var samples: [Double] = []
        for _ in 0..<6 {
            try await Task.sleep(for: .seconds(1))
            samples.append(engine.currentTime)
        }
        log("time samples while playing: \(samples.map { String(format: "%.2f", $0) }.joined(separator: " "))")
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $1 > $0 })
        #expect(samples.last! > 4)

        // 3. The URL "expires" mid-track: re-resolve and resume at the same position.
        let before = engine.currentTime
        engine.simulateStreamFailure("HTTP 403 (forced URL swap)")
        log("forced failure at \(String(format: "%.2f", before))s, state=\(events.lastState.map { "\($0)" } ?? "nil")")
        #expect(await waitUntil(timeout: 20) { events.lastState == .playing })
        let resumed = engine.currentTime
        try await Task.sleep(for: .seconds(2))
        let later = engine.currentTime
        log("resumed at \(String(format: "%.2f", resumed))s, 2s later \(String(format: "%.2f", later))s; resolves=\(resolver.calls) recoveries=\(engine.recoveryCount)")
        #expect(resolver.calls == 3)
        #expect(abs(resumed - before) < 1.5)
        #expect(later > resumed + 1)
        #expect(events.failures.isEmpty)

        // 4. Pause, then measure this process's CPU for 10 s.
        engine.pause()
        #expect(await waitUntil { events.lastState == .paused && !engine.isTimeObserverAttached })
        try await Task.sleep(for: .seconds(1))
        let marker = URL(fileURLWithPath: "/tmp/openmusic-live-paused.pid")
        try "\(getpid())".write(to: marker, atomically: true, encoding: .utf8)
        let timeEventsBefore = events.timeEvents
        let cpuBefore = Self.cpuSeconds()
        let wallBefore = Date()
        try await Task.sleep(for: .seconds(10))
        let cpu = Self.cpuSeconds() - cpuBefore
        let wall = Date().timeIntervalSince(wallBefore)
        try? FileManager.default.removeItem(at: marker)
        let percent = cpu / wall * 100
        log(String(format: "paused %.1fs: process CPU %.3fs = %.2f%%, time events while paused: %d", wall, cpu, percent, events.timeEvents - timeEventsBefore))
        #expect(events.timeEvents == timeEventsBefore)
        #expect(percent < 1)

        engine.stop()
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}
