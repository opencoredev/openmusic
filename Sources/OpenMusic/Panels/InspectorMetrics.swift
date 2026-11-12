import CoreGraphics

/// Widths of the lyrics and queue panel column. Constants on purpose: a width computed from the window or
/// the panel's content feeds back into the split view's layout and can loop AppKit's Update Constraints.
/// The ideal stays at 310 (a wider ideal looped at 960 pt); the maximum lets long lyric lines fit.
nonisolated enum InspectorMetrics {
    static let minWidth: CGFloat = 280
    static let idealWidth: CGFloat = 310
    static let maxWidth: CGFloat = 520
    /// Lyrics open this wide in a window of at least `wideLyricsWindow` points, so long lines read without
    /// stacking into narrow wraps. The queue stays at the ideal.
    static let lyricsWidth: CGFloat = 420
    static let wideLyricsWindow: CGFloat = 1300
}
