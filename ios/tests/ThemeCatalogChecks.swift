import Foundation

@main
struct ThemeCatalogChecks {
    static func main() {
        expect(ThemeCatalog.default == .dark, "default theme should remain dark")
        expect(ThemeID.allCases.count == 6, "expected six curated themes")

        expect(
            ThemeCatalog.resolve(rawValue: nil) == .dark,
            "missing persistence should fall back to dark"
        )
        expect(
            ThemeCatalog.resolve(rawValue: "not-a-theme") == .dark,
            "unknown persistence should fall back to dark"
        )
        expect(
            ThemeCatalog.resolve(rawValue: ThemeID.goldfish.rawValue) == .goldfish,
            "goldfish should round-trip from storage"
        )

        let dark = ThemeCatalog.palette(for: .dark)
        expect(dark.appearance == .dark, "dark theme uses dark appearance")
        expect(nearlyEqual(dark.accent.red, 0.02), "dark accent red channel")
        expect(nearlyEqual(dark.accent.green, 0.42), "dark accent green channel")
        expect(nearlyEqual(dark.accent.blue, 0.92), "dark accent blue channel")

        let light = ThemeCatalog.palette(for: .light)
        expect(light.appearance == .light, "light theme uses light appearance")
        expect(light.canvas.red > 0.9, "light canvas should be bright")
        expect(light.inkPrimary.red < 0.2, "light ink should be dark")

        let goldfish = ThemeCatalog.palette(for: .goldfish)
        expect(goldfish.appearance == .light, "goldfish is a light warm scheme")
        expect(goldfish.accent.red > 0.9, "goldfish accent should skew warm/red")
        expect(goldfish.accent.green > 0.3 && goldfish.accent.green < 0.6, "goldfish accent green")
        expect(goldfish.canvas.red > 0.95, "goldfish canvas should feel creamy")

        for id in ThemeID.allCases {
            let palette = ThemeCatalog.palette(for: id)
            expect(!id.title.isEmpty, "\(id.rawValue) needs a title")
            expect(!id.subtitle.isEmpty, "\(id.rawValue) needs a subtitle")
            expect(palette.accent.alpha > 0, "\(id.rawValue) accent must be visible")
            expect(palette.canvas.alpha > 0, "\(id.rawValue) canvas must be opaque")
            expect(
                palette.inkPrimary.contrastRatio(over: palette.canvas) >= 4.5,
                "\(id.rawValue) primary text must meet the AA contrast threshold"
            )
            expect(
                palette.inkSecondary.contrastRatio(over: palette.canvas) >= 4.5,
                "\(id.rawValue) secondary text must meet the AA contrast threshold"
            )
            expect(
                palette.accentForeground.contrastRatio(over: palette.accent) >= 4.5,
                "\(id.rawValue) accent actions must choose a readable foreground"
            )
            expect(
                palette.primarySurfaceForeground.contrastRatio(over: palette.inkPrimary) >= 4.5,
                "\(id.rawValue) primary-ink actions must choose a readable foreground"
            )
            expect(
                palette.dangerForeground.contrastRatio(over: palette.danger) >= 4.5,
                "\(id.rawValue) destructive actions must choose a readable foreground"
            )
            // Danger also appears as a bare tint and label, not only as a fill.
            expect(
                palette.danger.contrastRatio(over: palette.canvas) >= 3,
                "\(id.rawValue) danger must stay visible against its own canvas"
            )

            // Every demand step is drawn as a gauge stroke and a bold numeral
            // straight on the canvas. A single fixed ramp used to put a
            // near-white yellow on the light and Goldfish schemes.
            for step in DifficultyStep.allCases {
                expect(
                    palette.difficultyColor(step).contrastRatio(over: palette.canvas) >= 3,
                    "\(id.rawValue) difficulty step \(step) must stay legible on its canvas"
                )
            }
        }

        // The ramp must stay readable as a scale: easiest is the greenest,
        // hardest the reddest, in both appearances.
        for id in [ThemeID.dark, .light] {
            let palette = ThemeCatalog.palette(for: id)
            let easiest = palette.difficultyColor(.veryEasy)
            let hardest = palette.difficultyColor(.veryHard)
            expect(
                easiest.green > easiest.red,
                "\(id.rawValue) easiest demand step should read green"
            )
            expect(
                hardest.red > hardest.green,
                "\(id.rawValue) hardest demand step should read red"
            )
        }

        print("ThemeCatalog checks passed")
    }

    private static func nearlyEqual(_ value: Double, _ expected: Double, tolerance: Double = 0.001) -> Bool {
        abs(value - expected) <= tolerance
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError("ThemeCatalog check failed: \(message)")
        }
    }
}
