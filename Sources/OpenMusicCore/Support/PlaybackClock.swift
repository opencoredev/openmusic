import Foundation

/// Elapsed and remaining labels under a timeline. Both show whole seconds rounded down, so the remaining time is the
/// length's whole seconds minus the elapsed whole seconds: "1:12" and "-3:45" always add up to the "4:57" shown as the
/// song's length. Subtracting first and rounding after drifted a second (4:57.6 − 1:12.8 = 3:44.8, shown as "-3:44").
public enum PlaybackClock {
    /// Whole seconds left, never negative. A missing or non-finite length counts as 0.
    public static func remaining(elapsed: TimeInterval, total: TimeInterval?) -> TimeInterval {
        let length = wholeSeconds(total ?? 0)
        return max(0, length - wholeSeconds(elapsed))
    }

    /// `seconds` rounded down, with negative and non-finite values as 0.
    public static func wholeSeconds(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return seconds.rounded(.down)
    }
}
