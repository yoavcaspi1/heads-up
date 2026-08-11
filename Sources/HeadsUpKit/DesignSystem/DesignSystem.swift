import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// The app's design token set (colors, type scale, spacing, component
// metrics), maintained upstream as Style Dictionary JSON and hand-mirrored
// here (SwiftUI has no Style Dictionary transform yet). Treat values as
// generated: change them upstream, not ad hoc. Enum-namespaced tokens with
// a Color(light:dark:) helper; steel-blue accent + Syne / DM Sans / DM Mono
// type families.
public enum YCDesignSystem {

    // MARK: - Colors
    // Every pairing below is contrast-verified (relative luminance) against
    // both light/canvas and light/surface, or dark/canvas and dark/surface.
    // See tokens/semantic.yc.json and tokens/semantic.yc.dark.json for the
    // computed ratios token-by-token.

    public enum Colors {
        /// Page background. Warm off-white in light, not stark white.
        public static let canvas = Color(light: "#FAF8F5", dark: "#1B1D22")

        /// Card / panel / modal surface.
        public static let surface = Color(light: "#FFFFFF", dark: "#24262C")

        /// Table stripe, hover fill on a surface.
        public static let surfaceAlt = Color(light: "#F0ECE5", dark: "#2E3038")

        /// Dark surface for inverse sections (light theme) / light surface for
        /// inverse sections (dark theme) — e.g. a dark preferences sidebar.
        public static let surfaceInverse = Color(light: "#21242B", dark: "#FAF8F5")

        /// Default hairline border, decorative, exempt from the 3:1 UI minimum.
        public static let border = Color(light: "#E2DDD3", dark: "#383A42")

        /// Border that itself carries a state signal (needs 3:1+).
        public static let borderStrong = Color(light: "#C9C2B4", dark: "#4C4F59")

        /// Primary body text. 14.65:1 / 15.53:1 (light), 14.15:1 / 12.69:1 (dark).
        public static let textPrimary = Color(light: "#21242B", dark: "#EDEBE6")

        /// De-emphasised text. 6.52:1 / 6.91:1 (light), 8.14:1 / 7.30:1 (dark).
        public static let textSecondary = Color(light: "#565A63", dark: "#B7B4AC")

        /// Placeholder / helper / caption text. Clears 4.5:1 normal-text AA in
        /// both themes on both canvas and surface (4.61/4.89 light, 5.22/4.68 dark).
        public static let textMuted = Color(light: "#6E7178", dark: "#8C8F98")

        /// Text on an inverse (surfaceInverse) background.
        public static let textInverse = Color(light: "#FFFFFF", dark: "#21242B")

        /// Text/icon colour on a filled accent surface. 5.45:1 on the accent
        /// fill in both themes, clears full body-text AA outright (no
        /// large-text exception needed).
        public static let textOnAccent = Color(hex: "#FFFFFF")

        /// Primary accent, steel blue ("Harbor"). Same value in both themes —
        /// only hover/active and surrounding neutrals change.
        public static let accent = Color(hex: "#3E6E93")

        /// Hover fill. White text on this measures 7.31:1.
        public static let accentHover = Color(hex: "#335A78")

        /// Active/pressed fill. White text on this measures 9.30:1.
        public static let accentActive = Color(hex: "#2A4A63")

        /// Link text and focus ring colour. The base accent fails as a
        /// border/text colour on a dark surface (2.78:1, under the 3:1
        /// minimum), so dark mode uses a lightened tint instead (5.10:1 on
        /// dark surface). Light mode uses the base accent directly (5.45:1).
        public static let link = Color(light: "#3E6E93", dark: "#6C9BC0")

        /// Focus ring colour. Same value as `link`, named separately so a
        /// future divergence between the two doesn't require touching every
        /// call site.
        public static var focusRing: Color { link }

        /// Accent for live status indicators drawn as thin non-text shapes
        /// (equalizer bars, level meters). Same harbor/harbor-light split as
        /// `link`, for the same 3:1 non-text contrast reason, but named for
        /// its own role (color.action.indicator, v1.5.0).
        public static var indicator: Color { link }

        /// Neutral "secondary action" colour — deliberately ink/text-primary,
        /// not a second accent hue. A minimalist outlined secondary button
        /// reads calmer than a two-colour system.
        public static var actionSecondary: Color { textPrimary }

        public static let disabledBg = Color(light: "#E2DDD3", dark: "#383A42")
        public static let disabledText = Color(light: "#6E7178", dark: "#8C8F98")

        // Feedback (info / success / warning / danger). Muted, dusty tones,
        // never a bright alarm colour. Always pair with an icon and a text
        // label in UI, never colour alone.
        public static let infoText = Color(light: "#2C5573", dark: "#8FC0E0")
        public static let infoBg = Color(light: "#E8F0F5", dark: "#25313A")
        public static let successText = Color(light: "#3F6A4E", dark: "#8FC7A4")
        public static let successBg = Color(light: "#EAF2EC", dark: "#22322A")
        public static let warningText = Color(light: "#8A5E1E", dark: "#E0AE68")
        public static let warningBg = Color(light: "#FBF1E3", dark: "#3A2E1E")
        public static let dangerText = Color(light: "#A23B30", dark: "#E39187")
        public static let dangerBg = Color(light: "#FBEEEC", dark: "#3A2420")

        /// Modal/sheet backdrop scrim.
        public static let overlayScrim = Color(light: "rgba(33,36,43,0.55)", dark: "rgba(0,0,0,0.70)")

        /// Hover/selection wash for list rows — a neutral gray-family wash,
        /// never a blue fill on hover.
        public static let selectionHighlight = Color(light: "rgba(33,36,43,0.06)", dark: "rgba(255,255,255,0.06)")
        public static let selectionHighlightStrong = Color(light: "rgba(33,36,43,0.10)", dark: "rgba(255,255,255,0.09)")
    }

    // MARK: - Typography
    // Syne = structural headings (h1-h4, modal titles), 600 weight per the
    // shared theme-independent type scale (not decoration-only).
    // DM Sans = all body copy, labels, buttons, menu items.
    // DM Mono = data, code, kbd, timestamps, figures, metadata.
    //
    // Custom fonts must be bundled with the app (Info.plist UIAppFonts /
    // Fonts provided by application) for `ycFont` to resolve them; if a
    // named font isn't installed/registered, this falls back to the system
    // font at the same size/weight so nothing ever renders blank.

    public enum Typography {
        /// Full-screen alert hero title. Back-port to tokens as type.displayXL.
        public static let displayXL = ycFont("Syne-ExtraBold", size: 64, weight: .heavy)
        /// Full-screen alert time range. Back-port to tokens as type.dataLarge.
        public static let dataLarge = ycFont("DMMono-Medium", size: 24, weight: .medium, design: .monospaced)

        public static let display = ycFont("Syne-ExtraBold", size: 40, weight: .heavy)
        public static let h1 = ycFont("Syne-SemiBold", size: 24, weight: .semibold)

        /// DM Sans twins of the three display tiers the alert title steps
        /// through, for the "Alert title font" setting (conventional
        /// descenders instead of Syne's flat-chopped g/j).
        public static let displayXLSans = ycFont("DMSans-Black", size: 64, weight: .black)
        public static let displaySans = ycFont("DMSans-Black", size: 40, weight: .black)
        public static let h1Sans = ycFont("DMSans-ExtraBold", size: 24, weight: .heavy)
        public static let h2 = ycFont("Syne-SemiBold", size: 20, weight: .semibold)
        public static let h3 = ycFont("Syne-SemiBold", size: 17, weight: .semibold)
        public static let h4 = ycFont("Syne-Medium", size: 15, weight: .medium)

        public static let bodyLarge = ycFont("DMSans-Regular", size: 16, weight: .regular)
        public static let body = ycFont("DMSans-Regular", size: 14, weight: .regular)
        public static let bodySmall = ycFont("DMSans-Regular", size: 12, weight: .regular)
        public static let label = ycFont("DMSans-SemiBold", size: 12, weight: .semibold)
        public static let caption = ycFont("DMSans-Regular", size: 11, weight: .regular)
        public static let button = ycFont("DMSans-SemiBold", size: 13, weight: .semibold)

        /// Table figures, currency, timestamps. Tabular numerals via DM Mono.
        public static let data = ycFont("DMMono-Medium", size: 14, weight: .medium, design: .monospaced)
        public static let code = ycFont("DMMono-Regular", size: 12, weight: .regular, design: .monospaced)
    }

    /// Resolves a named font if it's registered with the system, falling
    /// back to `Font.system` (optionally monospaced) so a missing font
    /// bundle never breaks layout — only softens the type character.
    private static func ycFont(_ name: String, size: CGFloat, weight: Font.Weight, design: Font.Design = .default) -> Font {
        #if canImport(AppKit)
        if NSFont(name: name, size: size) != nil {
            return Font.custom(name, size: size)
        }
        #endif
        return Font.system(size: size, weight: weight, design: design)
    }

    // MARK: - Corner Radius
    // Same theme-independent scale as the web tokens (radius.sm/md/lg/xl/full).

    public enum CornerRadius {
        public static let none: CGFloat = 0
        public static let small: CGFloat = 4    // radius.sm
        public static let medium: CGFloat = 8   // radius.md — layout.radius.control (buttons, inputs, badges)
        public static let large: CGFloat = 12   // radius.lg — layout.radius.container (cards, modals, panels)
        public static let extraLarge: CGFloat = 16 // radius.xl
        public static let pill: CGFloat = 9999
    }

    // MARK: - Spacing
    // Same 4pt base scale as the web tokens (space.*).

    public enum Spacing {
        public static let xs: CGFloat = 4    // space.1
        public static let sm: CGFloat = 8    // space.2
        public static let smd: CGFloat = 12  // space.3
        public static let md: CGFloat = 16   // space.4 / layout.spacing.md
        public static let lg: CGFloat = 24   // space.6 / layout.spacing.lg
        public static let xl: CGFloat = 32   // space.8 / layout.spacing.xl
        public static let xxl: CGFloat = 48  // space.12 / layout.spacing.2xl
        public static let xxxl: CGFloat = 64 // space.16 / layout.spacing.3xl
    }

    // MARK: - Motion
    // Same duration scale as motion.duration.* / motion.* semantic aliases.

    public enum Motion {
        public static let micro: Double = 0.12       // motion.micro / motion.duration.fast
        public static let transition: Double = 0.20  // motion.transition / motion.duration.base
        public static let entrance: Double = 0.32     // motion.entrance / motion.duration.slow
        public static let loop: Double = 0.80         // motion.loop — one spinner rotation

        public static let standardAnimation = Animation.easeInOut(duration: transition)
        public static let microAnimation = Animation.easeInOut(duration: micro)
        public static let entranceAnimation = Animation.easeOut(duration: entrance)
        /// No bouncy nonsense: a restrained spring for hover/press feedback only.
        public static let pressAnimation = Animation.spring(response: 0.3, dampingFraction: 0.75)
    }

    // MARK: - Audio Equalizer (equalizer.*, v1.5.0)
    // Live voice-level indicator, the "your voice is being captured" cluster
    // of centre-weighted rounded bars. See COMPONENT SPECS/19_AUDIO_EQUALIZER.md.
    // Colours: active = Colors.indicator, idle = Colors.borderStrong,
    // muted/paused = Colors.textMuted. Always pair with a text state label;
    // hide the component entirely when there is no permission or signal.

    public enum Equalizer {
        /// Standard size: recording views, cards. Height matches control minHeight.
        public static let barCount = 9
        public static let height: CGFloat = 40
        public static let barWidth: CGFloat = 4
        public static let barGap: CGFloat = 4

        /// Compact size: menu bar, inline rows.
        public static let barCountCompact = 5
        public static let heightCompact: CGFloat = 18
        public static let barWidthCompact: CGFloat = 3
        public static let barGapCompact: CGFloat = 3

        /// Minimum bar height as a fraction of component height. Bars never
        /// vanish: at silence they rest as visible dots.
        public static let levelFloor: CGFloat = 0.16

        /// Asymmetric smoothing time constants, seconds. Rise fast, fall
        /// gracefully; apply per frame as k = 1 - exp(-dt / tau).
        public static let attack: Double = 0.060
        public static let release: Double = 0.240

        /// One breathing cycle of the idle dots (opacity pulse), seconds.
        public static let idlePulse: Double = 2.6

        /// Per-bar height envelope, tapering ~1.0 centre to ~0.35 edge:
        /// weight(i) = 0.35 + 0.65 * pow(cos(d * .pi / 2), 1.4)
        /// where d = |i - mid| / mid.
        public static func centreWeights(count: Int) -> [CGFloat] {
            guard count > 1 else { return [1] }
            let mid = CGFloat(count - 1) / 2
            return (0..<count).map { i in
                let d = abs(CGFloat(i) - mid) / mid
                return 0.35 + 0.65 * pow(cos(d * .pi / 2), 1.4)
            }
        }
    }

    // MARK: - Shadows
    // Approximates elevation.1-4 (0px1px2px / 0px2px6px / 0px6px16px / 0px12px32px)
    // as SwiftUI shadow(color:radius:y:).

    public enum Shadows {
        public static let none = ShadowStyle(color: .clear, radius: 0, y: 0)
        public static let resting = ShadowStyle(color: .black.opacity(0.08), radius: 2, y: 1)   // elevation.1
        public static let raised = ShadowStyle(color: .black.opacity(0.10), radius: 6, y: 2)    // elevation.2
        public static let overlay = ShadowStyle(color: .black.opacity(0.12), radius: 16, y: 6)  // elevation.3
        public static let modal = ShadowStyle(color: .black.opacity(0.15), radius: 32, y: 12)   // elevation.4
    }

    // MARK: - Rows
    // preferences.rowMinHeight (48px), from the preferences-pane component
    // spec (COMPONENT SPECS/17_PREFERENCES_PANE.md). Back-port to YC DESIGN
    // SYSTEM JSON (tokens/component.json) as preferences.rowMinHeight; this
    // is the manual Swift-side bridge value until that lands.

    public enum Rows {
        public static let minHeight: CGFloat = 48
    }

    // MARK: - Focus

    public enum Focus {
        public static let ringWidth: CGFloat = 2
        public static let ringOffset: CGFloat = 2
    }

    // MARK: - Z-Index (window/overlay level, for apps managing multiple NSWindow layers)

    public enum ZIndex {
        public static let base: Double = 0
        public static let dropdown: Double = 1000
        public static let sticky: Double = 1020
        public static let overlay: Double = 1040
        public static let modal: Double = 1050
        public static let tooltip: Double = 1070
        public static let toast: Double = 1080
    }
}

// MARK: - Shadow Style Helper

public struct ShadowStyle: Sendable {
    public let color: Color
    public let radius: CGFloat
    public let x: CGFloat
    public let y: CGFloat

    public init(color: Color, radius: CGFloat, x: CGFloat = 0, y: CGFloat) {
        self.color = color
        self.radius = radius
        self.x = x
        self.y = y
    }
}

// MARK: - Color Extension

extension Color {
    /// Create a color from a hex string or an rgba() string.
    init(hex: String) {
        if hex.lowercased().hasPrefix("rgba(") {
            let values = hex
                .replacingOccurrences(of: "rgba(", with: "")
                .replacingOccurrences(of: ")", with: "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if values.count >= 4,
               let r = Double(values[0]), let g = Double(values[1]),
               let b = Double(values[2]), let a = Double(values[3]) {
                self.init(.sRGB, red: r / 255.0, green: g / 255.0, blue: b / 255.0, opacity: a)
                return
            }
        }
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }

    /// Create an adaptive colour resolved per light/dark appearance.
    init(light: String, dark: String) {
        #if canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
                return NSColor(Color(hex: dark))
            } else {
                return NSColor(Color(hex: light))
            }
        })
        #else
        self.init(hex: light)
        #endif
    }
}

// MARK: - View Extensions

extension View {
    public func ycShadow(_ style: ShadowStyle) -> some View {
        self.shadow(color: style.color, radius: style.radius, x: style.x, y: style.y)
    }

    /// Visible, non-colour-only focus ring, offset per YCDesignSystem.Focus.
    public func ycFocusRing(_ isFocused: Bool) -> some View {
        self
            .overlay(
                RoundedRectangle(cornerRadius: YCDesignSystem.CornerRadius.medium)
                    .stroke(isFocused ? YCDesignSystem.Colors.focusRing : Color.clear, lineWidth: YCDesignSystem.Focus.ringWidth)
            )
            .animation(YCDesignSystem.Motion.microAnimation, value: isFocused)
    }

    /// Row hover/selection highlight — neutral gray family, never a colour fill.
    public func ycRowHighlight(isSelected: Bool, isHovered: Bool) -> some View {
        self.background(
            RoundedRectangle(cornerRadius: YCDesignSystem.CornerRadius.medium)
                .fill(isSelected ? YCDesignSystem.Colors.selectionHighlightStrong : (isHovered ? YCDesignSystem.Colors.selectionHighlight : Color.clear))
        )
        .animation(YCDesignSystem.Motion.microAnimation, value: isSelected)
        .animation(YCDesignSystem.Motion.microAnimation, value: isHovered)
    }
}
