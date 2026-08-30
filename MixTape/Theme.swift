import SwiftUI

/// Centralized color palette derived from Doppler's brand. One source of truth
/// for the three brand colors plus the dark-mode panel + border tones used by
/// containers across the app. Views import `Theme.*` instead of sprinkling raw
/// `Color(.sRGB, ...)` literals.
///
/// Brand colors (from the Doppler icon):
/// - `darkPurple`  rgb(72, 64, 168)   — deeper accent, used for borders /
///   secondary highlights where the lighter tone would be too loud.
/// - `lightPurple` rgb(108, 90, 204)  — primary accent. Also wired through
///   `Color.accentColor` via `Assets.xcassets/AccentColor.colorset`, so
///   buttons, toggles, and `.tint`-receiving controls inherit it for free.
/// - `lavender`    rgb(217, 213, 240) — pale tint used for icon glyphs and
///   subtle borders on dark backgrounds.
///
/// Container tones (two layers of elevation):
/// - `windowBackground` — the bottom layer. Near-black with a faint purple
///   cast. Painted on the main window + Settings via `.containerBackground`
///   so panels sit visibly on top instead of fighting macOS's default gray.
/// - `panel`            — card / group-box background. Noticeably lighter
///   than `windowBackground` so cards "pop" off the surface.
/// - `panelBorder`      — lavender at low alpha. Gives cards a definition
///   stroke that picks up the accent without being noisy.
///
/// `statTints` is a small ramp from light-purple to lavender, used by the
/// four `StatTile`s on My Doppler so each stat reads as distinct without
/// breaking the palette.
enum Theme {
    static let darkPurple  = Color(.sRGB, red: 72/255,  green: 64/255,  blue: 168/255, opacity: 1)
    static let lightPurple = Color(.sRGB, red: 108/255, green: 90/255,  blue: 204/255, opacity: 1)
    static let lavender    = Color(.sRGB, red: 217/255, green: 213/255, blue: 240/255, opacity: 1)

    static let windowBackground = Color(.sRGB, red: 12/255, green: 10/255, blue: 22/255, opacity: 1)
    static let panel            = Color(.sRGB, red: 40/255, green: 36/255, blue: 60/255, opacity: 1)
    static let panelBorder      = lavender.opacity(0.12)

    /// Distinct tints for the four stat tiles (Songs / Artists / Albums /
    /// Playlists). Stays inside the purple → lavender ramp so the page reads
    /// as one palette rather than four unrelated colors.
    static let statTints: [Color] = [
        lightPurple,
        Color(.sRGB, red: 142/255, green: 120/255, blue: 220/255, opacity: 1),
        Color(.sRGB, red: 175/255, green: 155/255, blue: 230/255, opacity: 1),
        lavender
    ]
}
