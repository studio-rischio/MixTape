import SwiftUI

/// Centralized color palette derived from the MixTape icon. One source of truth
/// for the brand colors plus the dark-mode panel + border tones used by
/// containers across the app. Views import `Theme.*` instead of sprinkling raw
/// `Color(.sRGB, ...)` literals.
///
/// **Every brand value below is sampled from the icon artwork, not invented** —
/// `MixTape.icon/Assets/RobotFace.svg` for the robot, `MixTape.icon/icon.json`
/// for the ground. If the icon is redrawn, re-sample rather than eyeballing:
/// the SVG stores plain `rgb(...)` fills, and `icon.json`'s `fill.solid` is
/// **Display P3** (`0.94141, 0.69043, 0.25879` → sRGB 252/173/23), so it has to
/// be converted before it can sit next to the others.
///
/// Brand colors:
/// - `amber`  rgb(251, 172, 23)  — the icon's ground and its eyes/mouth, so the
///   app's identity color. Used for headings, glyphs and highlights **on dark
///   surfaces**, where it lands at 8:1 or better. Not used as a fill behind
///   white text: it's a light color, and white on it is ~1.9:1.
/// - `gold`   rgb(232, 182, 81)  — the muted amber in the icon's shading. A
///   second warm tone for places that need two distinct highlights.
/// - `sky`    rgb(24, 195, 251)  — the robot's ears. The cool counterweight.
/// - `deepSky` rgb(14, 127, 196) — `sky` darkened until white text clears 4.3:1.
///   **This is the accent color**, mirrored in
///   `Assets.xcassets/AccentColor.colorset` so buttons, toggles, pickers and
///   `.tint`-receiving controls inherit it for free. It exists because neither
///   `amber` nor `sky` can carry a white label: the six `.borderedProminent`
///   buttons in the app would have been unreadable. Change it only to something
///   equally dark, or those buttons regress.
/// - `cream`  rgb(243, 236, 218) — the robot's face. Pale tint for section
///   labels and subtle borders on dark backgrounds.
/// - `navy`   rgb(8, 22, 47)     — the icon's outlines, and the hue the two
///   container tones below are darkened out of.
///
/// Status color:
/// - `warning` rgb(219, 104, 82) — the coral in the icon's antenna. Replaces
///   SwiftUI's `.orange` for every user-facing warning and failure, because
///   `.orange` is now within a few degrees of `amber` and "this failed" would
///   read as ordinary brand chrome. Success states keep the system `.green`.
///
/// Container tones (two layers of elevation):
/// - `windowBackground` — the bottom layer. Near-black with a navy cast.
///   Painted on the main window + Settings via `.containerBackground` so panels
///   sit visibly on top instead of fighting macOS's default gray.
/// - `panel`            — card / group-box background. Lifted off
///   `windowBackground` by the same ratio the old purple palette used (1.31),
///   so cards "pop" by exactly as much as they did before.
/// - `panelBorder`      — cream at low alpha. Gives cards a definition stroke
///   that picks up the palette without being noisy.
///
/// `statTints` is warm→cool across the two brand families, used by the four
/// `StatTile`s on My Doppler so each stat reads as distinct without breaking
/// the palette.
enum Theme {
    static let amber   = Color(.sRGB, red: 251/255, green: 172/255, blue: 23/255,  opacity: 1)
    static let gold    = Color(.sRGB, red: 232/255, green: 182/255, blue: 81/255,  opacity: 1)
    static let sky     = Color(.sRGB, red: 24/255,  green: 195/255, blue: 251/255, opacity: 1)
    static let deepSky = Color(.sRGB, red: 14/255,  green: 127/255, blue: 196/255, opacity: 1)
    static let cream   = Color(.sRGB, red: 243/255, green: 236/255, blue: 218/255, opacity: 1)
    static let navy    = Color(.sRGB, red: 8/255,   green: 22/255,  blue: 47/255,  opacity: 1)

    static let warning = Color(.sRGB, red: 219/255, green: 104/255, blue: 82/255,  opacity: 1)

    static let windowBackground = Color(.sRGB, red: 7/255,  green: 12/255, blue: 24/255, opacity: 1)
    static let panel            = Color(.sRGB, red: 26/255, green: 39/255, blue: 64/255, opacity: 1)
    static let panelBorder      = cream.opacity(0.12)

    /// Distinct tints for the four stat tiles (Songs / Artists / Albums /
    /// Playlists). Runs warm → cool so the row reads as one deliberate palette
    /// rather than four unrelated colors. The pale sky at the end is `sky`
    /// lightened; it's the only value here not lifted straight from the icon.
    static let statTints: [Color] = [
        amber,
        gold,
        sky,
        Color(.sRGB, red: 134/255, green: 220/255, blue: 253/255, opacity: 1)
    ]
}
