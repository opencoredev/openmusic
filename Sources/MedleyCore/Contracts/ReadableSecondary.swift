import SwiftUI

/// Secondary text in list rows (artist lines, albums, durations, track numbers), the queue panel, card captions,
/// section subtitles, empty states and Settings' explanations and values. The system `.secondary` is a translucent
/// label color that the inspector's vibrancy, the row selection fills and the grouped form's fill dim to about
/// 3–4:1; this is an opaque gray that stays at 4.5:1 or more for 12 pt text on every fill it sits on: the page and the
/// inspector at rest, the hover tint, the gray unfocused selection and the grouped form (measured on the council
/// captures). On the focused accent selection (`SelectionFill`) it turns white, like a native table's text.
/// Hierarchy against the titles comes from size and weight. Increased Contrast goes a step further. In MedleyCore so
/// the services' own settings views use it too.
public struct ReadableSecondary: ShapeStyle {
    /// Over the floating player's glass (`glassLight` / `glassDark`) instead of a page or panel fill.
    public var onGlass = false

    public init(onGlass: Bool = false) { self.onGlass = onGlass }

    public func resolve(in environment: EnvironmentValues) -> Color {
        // On a native table's emphasized (accent) selection the row's text turns white; so does this.
        if environment.backgroundProminence == .increased { return .white }
        let increased = environment.colorSchemeContrast == .increased
        return environment.colorScheme == .dark
            ? Color(white: increased ? 0.86 : onGlass ? ReadableSecondary.glassDark : ReadableSecondary.dark)
            : Color(white: increased ? 0.2 : onGlass ? ReadableSecondary.glassLight : ReadableSecondary.light)
    }

    /// sRGB gray levels. Light 0.28 (#474747): 7.8:1 on the inspector's gray, 5.1:1 on the most saturated playlist
    /// hero tint behind the first rows (4.6:1 with the hover tint over it). Dark 0.72 (#B8B8B8): 7.9:1 on the
    /// inspector, 4.9:1 on the hero tint behind the first rows.
    public static let light: Double = 0.28
    public static let dark: Double = 0.72
    /// On the player's glass, whose brightness follows the page beneath it: art scrolling under the capsule makes the
    /// light glass darker and the dark glass lighter than a panel, so these sit a step further from the glass.
    public static let glassLight: Double = 0.26
    public static let glassDark: Double = 0.8
}

public extension ShapeStyle where Self == ReadableSecondary {
    /// Opaque secondary text for rows and panels (`ReadableSecondary`).
    static var readableSecondary: ReadableSecondary { ReadableSecondary() }
    /// Opaque secondary text on the floating player's glass (artist line, times).
    static var glassSecondary: ReadableSecondary { ReadableSecondary(onGlass: true) }
}
