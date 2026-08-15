import Foundation

/// Stable identifiers for on-device appearance presets.
enum ThemeID: String, CaseIterable, Codable, Identifiable, Equatable {
    case dark
    case light
    case goldfish
    case midnight
    case ember
    case sequoia

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .goldfish: "Goldfish"
        case .midnight: "Midnight"
        case .ember: "Ember"
        case .sequoia: "Sequoia"
        }
    }

    var subtitle: String {
        switch self {
        case .dark: "Original Roam blue on soft black"
        case .light: "Bright canvas with dark ink"
        case .goldfish: "Warm coral on a soft cream pond"
        case .midnight: "Cyan signals on deep navy"
        case .ember: "Amber glow on charcoal"
        case .sequoia: "Mint accents in a forest dusk"
        }
    }
}

enum ThemeAppearance: String, Codable, Equatable {
    case light
    case dark
}

/// Device-independent color channel values for theme palettes.
struct RGBA: Equatable, Codable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    static func rgb(_ red: Double, _ green: Double, _ blue: Double, alpha: Double = 1) -> RGBA {
        RGBA(red: red, green: green, blue: blue, alpha: alpha)
    }

    static func white(opacity: Double) -> RGBA {
        RGBA(red: 1, green: 1, blue: 1, alpha: opacity)
    }

    static func black(opacity: Double) -> RGBA {
        RGBA(red: 0, green: 0, blue: 0, alpha: opacity)
    }

    /// WCAG contrast after compositing translucent foregrounds over a surface.
    /// Keeping this in the platform-independent theme model lets every color
    /// scheme be checked from a command-line test as well as in SwiftUI.
    func contrastRatio(over background: RGBA) -> Double {
        let opaqueBackground = background.composited(over: .white(opacity: 1))
        let opaqueForeground = composited(over: opaqueBackground)
        let lighter = max(opaqueForeground.relativeLuminance, opaqueBackground.relativeLuminance)
        let darker = min(opaqueForeground.relativeLuminance, opaqueBackground.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func composited(over background: RGBA) -> RGBA {
        let foregroundAlpha = alpha.clampedToUnit
        let backgroundAlpha = background.alpha.clampedToUnit
        let outputAlpha = foregroundAlpha + backgroundAlpha * (1 - foregroundAlpha)
        guard outputAlpha > 0 else { return .rgb(0, 0, 0, alpha: 0) }

        func channel(_ foreground: Double, _ background: Double) -> Double {
            (foreground.clampedToUnit * foregroundAlpha
                + background.clampedToUnit * backgroundAlpha * (1 - foregroundAlpha)) / outputAlpha
        }

        return .rgb(
            channel(red, background.red),
            channel(green, background.green),
            channel(blue, background.blue),
            alpha: outputAlpha
        )
    }

    private var relativeLuminance: Double {
        func linearized(_ channel: Double) -> Double {
            let value = channel.clampedToUnit
            return value <= 0.04045
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * linearized(red)
            + 0.7152 * linearized(green)
            + 0.0722 * linearized(blue)
    }

    static func readableForeground(over background: RGBA) -> RGBA {
        let light = RGBA.white(opacity: 1)
        let dark = RGBA.black(opacity: 1)
        return light.contrastRatio(over: background) >= dark.contrastRatio(over: background)
            ? light
            : dark
    }
}

private extension Double {
    var clampedToUnit: Double { max(0, min(1, self)) }
}

/// The five demand steps, ordered easiest to hardest. Declared here so the
/// difficulty ramp lives beside the palettes it has to stay legible against.
enum DifficultyStep: Int, CaseIterable {
    case veryEasy
    case easy
    case moderate
    case hard
    case veryHard
}

struct ThemePalette: Equatable {
    let accent: RGBA
    let safety: RGBA
    /// Destructive actions — ending a drive, deleting history. Distinct from
    /// `safety`, which warns without destroying anything.
    let danger: RGBA
    let positive: RGBA
    let canvas: RGBA
    let cardSurface: RGBA
    let cardSurfaceElevated: RGBA
    let cardStroke: RGBA
    let cardStrokeStrong: RGBA
    let inkPrimary: RGBA
    let inkSecondary: RGBA
    let inkTertiary: RGBA
    let inkLabel: RGBA
    let cardShadow: RGBA
    /// Fill for controls that are present but unavailable. Replaces
    /// `Color(.systemGray3)`, which only tracks light/dark and so ignored
    /// every theme beyond Dark and Light.
    let disabledSurface: RGBA
    /// Top-edge sheen on translucent glass surfaces. A light scheme needs a
    /// stronger highlight than a dark one to read as a lit edge.
    let glassHighlight: RGBA
    let appearance: ThemeAppearance

    /// Foreground chosen from black and white for the selected accent. This
    /// prevents a warm or bright theme from inheriting illegible white CTA text.
    var accentForeground: RGBA { .readableForeground(over: accent) }

    /// Foreground for primary actions that intentionally use the theme's
    /// primary ink as their filled surface.
    var primarySurfaceForeground: RGBA { .readableForeground(over: inkPrimary) }

    /// Foreground for destructive filled controls.
    var dangerForeground: RGBA { .readableForeground(over: danger) }

    /// Fixed green-to-red demand ramp. The hues stay constant so the scale
    /// remains learnable between themes, but a light canvas needs the darker
    /// end of each hue — the old single ramp put near-white yellow on cream.
    func difficultyColor(_ step: DifficultyStep) -> RGBA {
        let ramp = appearance == .dark
            ? ThemeCatalog.darkDifficultyRamp
            : ThemeCatalog.lightDifficultyRamp
        return ramp[step.rawValue]
    }
}

enum ThemeCatalog {
    static let `default`: ThemeID = .dark

    static func palette(for id: ThemeID) -> ThemePalette {
        switch id {
        case .dark: dark
        case .light: light
        case .goldfish: goldfish
        case .midnight: midnight
        case .ember: ember
        case .sequoia: sequoia
        }
    }

    /// Restores a saved raw value, falling back to the default when unknown.
    static func resolve(rawValue: String?) -> ThemeID {
        guard let rawValue, let id = ThemeID(rawValue: rawValue) else {
            return `default`
        }
        return id
    }

    /// Bright ramp for dark canvases.
    static let darkDifficultyRamp: [RGBA] = [
        .rgb(0.30, 0.82, 0.45),
        .rgb(0.48, 0.86, 0.42),
        .rgb(0.97, 0.78, 0.22),
        .rgb(1.00, 0.60, 0.25),
        .rgb(1.00, 0.42, 0.32),
    ]

    /// Deepened ramp for light canvases, where the bright ramp washes out.
    static let lightDifficultyRamp: [RGBA] = [
        .rgb(0.08, 0.48, 0.22),
        .rgb(0.16, 0.53, 0.20),
        .rgb(0.62, 0.44, 0.02),
        .rgb(0.76, 0.36, 0.04),
        .rgb(0.76, 0.16, 0.12),
    ]

    private static let dark = ThemePalette(
        accent: .rgb(0.02, 0.42, 0.92),
        safety: .rgb(1.0, 0.58, 0.0),
        danger: .rgb(0.82, 0.18, 0.17),
        positive: .rgb(0.20, 0.78, 0.35),
        canvas: .rgb(18 / 255, 18 / 255, 18 / 255),
        cardSurface: .rgb(30 / 255, 30 / 255, 30 / 255),
        cardSurfaceElevated: .rgb(36 / 255, 36 / 255, 36 / 255),
        cardStroke: .white(opacity: 0.10),
        cardStrokeStrong: .white(opacity: 0.16),
        inkPrimary: .rgb(241 / 255, 241 / 255, 241 / 255),
        inkSecondary: .white(opacity: 0.60),
        inkTertiary: .white(opacity: 0.38),
        inkLabel: .white(opacity: 0.64),
        cardShadow: .black(opacity: 0.28),
        disabledSurface: .white(opacity: 0.14),
        glassHighlight: .white(opacity: 0.20),
        appearance: .dark
    )

    private static let light = ThemePalette(
        accent: .rgb(0.02, 0.42, 0.92),
        safety: .rgb(0.90, 0.45, 0.05),
        danger: .rgb(0.78, 0.12, 0.12),
        positive: .rgb(0.12, 0.62, 0.30),
        canvas: .rgb(0.97, 0.95, 0.90),
        cardSurface: .rgb(0.99, 0.98, 0.94),
        cardSurfaceElevated: .rgb(0.98, 0.96, 0.92),
        cardStroke: .black(opacity: 0.08),
        cardStrokeStrong: .black(opacity: 0.14),
        inkPrimary: .rgb(0.10, 0.10, 0.12),
        inkSecondary: .black(opacity: 0.58),
        inkTertiary: .black(opacity: 0.55),
        inkLabel: .black(opacity: 0.56),
        cardShadow: .black(opacity: 0.10),
        disabledSurface: .black(opacity: 0.12),
        glassHighlight: .white(opacity: 0.52),
        appearance: .light
    )

    private static let goldfish = ThemePalette(
        accent: .rgb(1.0, 0.45, 0.18),
        safety: .rgb(0.92, 0.28, 0.18),
        danger: .rgb(0.74, 0.10, 0.10),
        positive: .rgb(0.18, 0.62, 0.42),
        canvas: .rgb(1.0, 0.96, 0.90),
        cardSurface: .rgb(1.0, 0.99, 0.96),
        cardSurfaceElevated: .rgb(1.0, 0.97, 0.92),
        cardStroke: .rgb(0.85, 0.55, 0.28, alpha: 0.28),
        cardStrokeStrong: .rgb(0.85, 0.45, 0.18, alpha: 0.40),
        inkPrimary: .rgb(0.28, 0.14, 0.06),
        inkSecondary: .rgb(0.42, 0.24, 0.10, alpha: 0.82),
        inkTertiary: .rgb(0.42, 0.24, 0.10, alpha: 0.70),
        inkLabel: .rgb(0.42, 0.24, 0.10, alpha: 0.74),
        cardShadow: .rgb(0.70, 0.35, 0.10, alpha: 0.14),
        disabledSurface: .rgb(0.42, 0.24, 0.10, alpha: 0.16),
        glassHighlight: .white(opacity: 0.58),
        appearance: .light
    )

    private static let midnight = ThemePalette(
        accent: .rgb(0.20, 0.82, 0.92),
        safety: .rgb(1.0, 0.62, 0.28),
        danger: .rgb(0.84, 0.20, 0.30),
        positive: .rgb(0.35, 0.86, 0.62),
        canvas: .rgb(0.05, 0.08, 0.16),
        cardSurface: .rgb(0.09, 0.13, 0.24),
        cardSurfaceElevated: .rgb(0.12, 0.17, 0.30),
        cardStroke: .white(opacity: 0.10),
        cardStrokeStrong: .white(opacity: 0.18),
        inkPrimary: .rgb(0.90, 0.95, 1.0),
        inkSecondary: .white(opacity: 0.62),
        inkTertiary: .white(opacity: 0.40),
        inkLabel: .white(opacity: 0.66),
        cardShadow: .black(opacity: 0.34),
        disabledSurface: .white(opacity: 0.14),
        glassHighlight: .white(opacity: 0.22),
        appearance: .dark
    )

    private static let ember = ThemePalette(
        accent: .rgb(0.98, 0.62, 0.18),
        safety: .rgb(1.0, 0.42, 0.18),
        danger: .rgb(0.80, 0.16, 0.12),
        positive: .rgb(0.45, 0.82, 0.38),
        canvas: .rgb(0.10, 0.08, 0.07),
        cardSurface: .rgb(0.16, 0.12, 0.10),
        cardSurfaceElevated: .rgb(0.20, 0.15, 0.12),
        cardStroke: .white(opacity: 0.10),
        cardStrokeStrong: .white(opacity: 0.16),
        inkPrimary: .rgb(0.98, 0.94, 0.88),
        inkSecondary: .white(opacity: 0.60),
        inkTertiary: .white(opacity: 0.38),
        inkLabel: .white(opacity: 0.64),
        cardShadow: .black(opacity: 0.32),
        disabledSurface: .white(opacity: 0.14),
        glassHighlight: .white(opacity: 0.20),
        appearance: .dark
    )

    private static let sequoia = ThemePalette(
        accent: .rgb(0.35, 0.78, 0.58),
        safety: .rgb(0.95, 0.55, 0.20),
        danger: .rgb(0.80, 0.19, 0.19),
        positive: .rgb(0.45, 0.86, 0.55),
        canvas: .rgb(0.07, 0.11, 0.09),
        cardSurface: .rgb(0.11, 0.16, 0.13),
        cardSurfaceElevated: .rgb(0.14, 0.20, 0.16),
        cardStroke: .white(opacity: 0.10),
        cardStrokeStrong: .white(opacity: 0.16),
        inkPrimary: .rgb(0.90, 0.96, 0.92),
        inkSecondary: .white(opacity: 0.60),
        inkTertiary: .white(opacity: 0.38),
        inkLabel: .white(opacity: 0.64),
        cardShadow: .black(opacity: 0.30),
        disabledSurface: .white(opacity: 0.14),
        glassHighlight: .white(opacity: 0.20),
        appearance: .dark
    )
}
