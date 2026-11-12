import Testing
@testable import OpenMusic

/// With Reduce Motion every custom transition is a crossfade and nothing scales, slides, rises or turns.
@MainActor
struct ReduceMotionTests {
    @Test func everyCustomTransitionIsAFadeWithReduceMotion() {
        for transition in Motion.Transition.allCases {
            #expect(transition.movement(reduce: true) == .fade, "\(transition)")
            // Without it each one still moves; otherwise it wouldn't need a Reduce Motion choice.
            #expect(transition.movement(reduce: false).isSpatial, "\(transition)")
        }
    }

    @Test func fullScreenPlayerEntryNoLongerScales() {
        #expect(Motion.Transition.fullScreenPlayer.movement(reduce: false) == .fadeScale(0.98))
        #expect(Motion.Transition.fullScreenPlayer.movement(reduce: true) == .fade)
        // A short crossfade for opening and closing alike.
        #expect(Motion.fullScreenToggleDuration(opening: true, reduce: true) <= 0.15)
        #expect(Motion.fullScreenToggleDuration(opening: false, reduce: true) <= 0.15)
        #expect(Motion.fullScreenToggleDuration(opening: true, reduce: false) == 0.3)
    }

    @Test func noticesDontRiseWithReduceMotion() {
        #expect(Motion.Transition.miniPlayerNotice.movement(reduce: false) == .fadeOffset(x: 0, y: -6))
        #expect(Motion.Transition.browsingNotice.movement(reduce: true) == .fade)
        #expect(Motion.Transition.fullScreenNotice.movement(reduce: true) == .fade)
        #expect(Motion.Transition.miniPlayerNotice.movement(reduce: true) == .fade)
    }

    @Test func expansionsAreImmediateWithReduceMotion() {
        for expansion in Motion.Expansion.allCases {
            #expect(expansion.animation(reduce: true) == nil, "\(expansion)")
            #expect(expansion.animation(reduce: false) != nil, "\(expansion)")
        }
    }

    @Test func chevronSwapsInsteadOfTurning() {
        #expect(Motion.chevron(open: true, reduce: false) == ("chevron.down", 180))
        #expect(Motion.chevron(open: true, reduce: true) == ("chevron.up", 0))
        #expect(Motion.chevron(open: false, reduce: true) == ("chevron.down", 0))
    }

    @Test func pressHoverAndPauseScalesAreOffWithReduceMotion() {
        for value in [0.9, Motion.pressScale, 0.94, 0.97, 1.04, 0.5] {
            #expect(Motion.scale(value, reduce: true) == 1)
            #expect(Motion.scale(value, reduce: false) == value)
        }
    }

    /// Every way into or out of the full-screen player goes through one method, so all of them get the same choice.
    @Test func fullScreenToggleGoesThroughTheModel() {
        let model = AppModel(environment: ["OPENMUSIC_MOCK": "1"])
        model.setFullScreenPlayerPresented(true, reduceMotion: true)
        #expect(model.isFullScreenPlayerPresented)
        model.setFullScreenPlayerPresented(false, reduceMotion: true)
        #expect(!model.isFullScreenPlayerPresented)
    }
}
