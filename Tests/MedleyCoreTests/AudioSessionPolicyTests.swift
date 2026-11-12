import Foundation
import Testing
@testable import MedleyCore

/// The interruption and session-lifetime rules behind the iOS `AudioSessionController`.
struct AudioSessionPolicyTests {
    @Test func interruptionPausesAndResumesWhenIOSAllows() {
        var policy = AudioSessionPolicy()
        policy.command(.play)
        let r1 = policy.interruptionBegan(isPlayingLocally: true, appWasSuspended: false)
        #expect(r1)
        #expect(policy.resumeAfterInterruption)
        let r2 = policy.interruptionEnded(shouldResume: true)
        #expect(r2)
        #expect(!policy.resumeAfterInterruption)
        #expect(!policy.isInterrupted)
    }

    @Test func explicitPauseDuringInterruptionCancelsAutoResume() {
        // A call pauses playback; the listener (or Siri) then says Pause; the call ends with .shouldResume.
        var policy = AudioSessionPolicy()
        policy.command(.play)
        let r3 = policy.interruptionBegan(isPlayingLocally: true, appWasSuspended: false)
        #expect(r3)
        policy.command(.pause)
        let r4 = policy.interruptionEnded(shouldResume: true)
        #expect(!r4)
        #expect(!policy.wantsPlayback)
    }

    @Test func explicitStopDuringInterruptionCancelsAutoResume() {
        var policy = AudioSessionPolicy()
        policy.command(.play)
        _ = policy.interruptionBegan(isPlayingLocally: true, appWasSuspended: false)
        policy.command(.stop)
        let r5 = policy.interruptionEnded(shouldResume: true)
        #expect(!r5)
    }

    @Test func lateStateUpdateDuringInterruptionDoesNotDisarm() {
        var policy = AudioSessionPolicy()
        policy.command(.play)
        _ = policy.interruptionBegan(isPlayingLocally: true, appWasSuspended: false)
        // A "playing" from before the pause arrives after .began.
        policy.playbackStarted()
        let r6 = policy.interruptionEnded(shouldResume: true)
        #expect(r6)
    }

    @Test func noResumeWithoutShouldResume() {
        var policy = AudioSessionPolicy()
        _ = policy.interruptionBegan(isPlayingLocally: true, appWasSuspended: false)
        let r7 = policy.interruptionEnded(shouldResume: false)
        #expect(!r7)
        // And the arming doesn't leak into the next interruption.
        _ = policy.interruptionBegan(isPlayingLocally: false, appWasSuspended: false)
        let r8 = policy.interruptionEnded(shouldResume: true)
        #expect(!r8)
    }

    @Test func interruptionWhilePausedOrRemoteDoesNothing() {
        var policy = AudioSessionPolicy()
        let r9 = policy.interruptionBegan(isPlayingLocally: false, appWasSuspended: false)
        #expect(!r9)
        let r10 = policy.interruptionEnded(shouldResume: true)
        #expect(!r10)
    }

    @Test func lateBeganForSuspendedAppIsIgnored() {
        var policy = AudioSessionPolicy()
        let r11 = policy.interruptionBegan(isPlayingLocally: true, appWasSuspended: true)
        #expect(!r11)
        #expect(!policy.isInterrupted)
        #expect(!policy.resumeAfterInterruption)
    }

    @Test func activatingEndsAnInterruptionWithoutEnded() {
        var policy = AudioSessionPolicy()
        _ = policy.interruptionBegan(isPlayingLocally: true, appWasSuspended: false)
        policy.command(.play)
        policy.sessionActivated()
        #expect(!policy.isInterrupted)
        #expect(policy.sessionAction(isPlaying: false, isLocal: true, isActive: true, inBackground: true) == .deactivateAfterGrace)
    }

    @Test func sessionIsHeldOnlyForLocalAudio() {
        let policy = AudioSessionPolicy()
        // Local playback starting: activate (once).
        #expect(policy.sessionAction(isPlaying: true, isLocal: true, isActive: false, inBackground: false) == .activate)
        #expect(policy.sessionAction(isPlaying: true, isLocal: true, isActive: true, inBackground: true) == .none)
        // Spotify Connect playing: never activate, and let go of a session held from earlier local audio.
        #expect(policy.sessionAction(isPlaying: true, isLocal: false, isActive: false, inBackground: false) == .none)
        #expect(policy.sessionAction(isPlaying: true, isLocal: false, isActive: true, inBackground: false) == .deactivate)
        // Queue cleared.
        #expect(policy.sessionAction(isPlaying: false, isLocal: false, isActive: true, inBackground: false) == .deactivate)
    }

    @Test func idleLocalSessionIsReleasedOnlyInTheBackground() {
        let policy = AudioSessionPolicy()
        #expect(policy.sessionAction(isPlaying: false, isLocal: true, isActive: true, inBackground: false) == .none)
        #expect(policy.sessionAction(isPlaying: false, isLocal: true, isActive: true, inBackground: true) == .deactivateAfterGrace)
        #expect(policy.sessionAction(isPlaying: false, isLocal: true, isActive: false, inBackground: true) == .none)
    }

    @Test func interruptedSessionIsLeftToTheSystem() {
        var policy = AudioSessionPolicy()
        _ = policy.interruptionBegan(isPlayingLocally: true, appWasSuspended: false)
        #expect(policy.sessionAction(isPlaying: false, isLocal: true, isActive: true, inBackground: true) == .none)
        #expect(policy.sessionAction(isPlaying: false, isLocal: false, isActive: true, inBackground: false) == .none)
    }

    @Test func mediaResetResumesOnlyWhatTheListenerWanted() {
        var policy = AudioSessionPolicy()
        #expect(!policy.resumeAfterMediaReset)
        policy.command(.play)
        #expect(policy.resumeAfterMediaReset)
        policy.command(.pause)
        #expect(!policy.resumeAfterMediaReset)
        policy.playbackStarted()
        #expect(policy.resumeAfterMediaReset)
        // Paused by an interruption: stay paused; the interruption's end decides.
        _ = policy.interruptionBegan(isPlayingLocally: true, appWasSuspended: false)
        #expect(!policy.resumeAfterMediaReset)
    }
}
