import Foundation
import Testing
@testable import OpenMusicCore

struct PlaybackClockTests {
    /// Elapsed and remaining, both in whole seconds, add up to the length's whole seconds.
    @Test func elapsedPlusRemainingIsTheLength() {
        for total in [297.6, 297.0, 180.999, 3725.4] {
            for elapsed in stride(from: 0.0, through: total, by: 0.37) {
                let remaining = PlaybackClock.remaining(elapsed: elapsed, total: total)
                #expect(remaining == remaining.rounded(.down))
                #expect(elapsed.rounded(.down) + remaining == total.rounded(.down))
            }
        }
    }

    @Test func the4m57Example() {
        // 1:12.8 into 4:57.6: "1:12" and "-3:45", not "-3:44".
        #expect(PlaybackClock.remaining(elapsed: 72.8, total: 297.6) == 225)
    }

    @Test func edgeCases() {
        #expect(PlaybackClock.remaining(elapsed: 10, total: nil) == 0)
        #expect(PlaybackClock.remaining(elapsed: 400, total: 297) == 0)
        #expect(PlaybackClock.remaining(elapsed: -3, total: 60.5) == 60)
        #expect(PlaybackClock.remaining(elapsed: .nan, total: .infinity) == 0)
    }
}
