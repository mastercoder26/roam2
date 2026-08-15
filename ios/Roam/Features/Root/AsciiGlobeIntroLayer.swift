import SwiftUI

/// The opening beat of the launch intro: a globe built entirely from
/// monospaced text glyphs, spinning as it settles in, that hands off into
/// `LaunchIntroView`'s wordmark reveal.
///
/// This replaces the old pre-rendered video clip. Same silhouette — globe
/// settles in, then the whole scene fades to canvas — but drawn live from
/// the active theme's own palette instead of six baked renders that had to
/// be re-exported whenever a theme changed.
struct AsciiGlobeIntroLayer: View {
    let themeID: ThemeID
    let onFinished: () -> Void

    var body: some View {
        AsciiGlobeScene(palette: ThemeCatalog.palette(for: themeID))
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + LaunchIntroChoreography.videoDuration) {
                    onFinished()
                }
            }
    }
}

// MARK: - Scene

private struct AsciiGlobeScene: View {
    let palette: ThemePalette

    @State private var startDate = Date()

    var body: some View {
        GeometryReader { geometry in
            let radius = AsciiGlobeMetrics.radius(for: geometry.size)
            let spacing = AsciiGlobeMetrics.spacing(for: radius)
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height * 0.39)
            let glyphs = AsciiGlobe.glyphs(radius: radius, spacing: spacing)

            TimelineView(.periodic(from: startDate, by: AsciiGlobeMetrics.frameInterval)) { timeline in
                let elapsed = timeline.date.timeIntervalSince(startDate)

                Canvas { context, _ in
                    draw(in: &context, center: center, radius: radius, spacing: spacing, glyphs: glyphs, elapsed: elapsed)
                }
            }
        }
        .background(palette.canvas.color)
    }

    private func draw(
        in context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        spacing: CGFloat,
        glyphs: [GlobeGlyph],
        elapsed: TimeInterval
    ) {
        let sceneOpacity = AsciiGlobeMetrics.sceneOpacity(elapsed: elapsed)
        guard sceneOpacity > 0 else { return }

        drawAtmosphere(in: &context, center: center, radius: radius, sceneOpacity: sceneOpacity)
        drawGlobe(in: &context, center: center, glyphs: glyphs, spacing: spacing, elapsed: elapsed, sceneOpacity: sceneOpacity)
    }

    /// A soft bloom behind the globe so the glyphs read as a lit sphere
    /// rather than text pasted on a flat background.
    private func drawAtmosphere(in context: inout GraphicsContext, center: CGPoint, radius: CGFloat, sceneOpacity: Double) {
        let bloomRadius = radius * 1.35
        let bloom = Path(ellipseIn: CGRect(
            x: center.x - bloomRadius,
            y: center.y - bloomRadius,
            width: bloomRadius * 2,
            height: bloomRadius * 2
        ))
        context.opacity = sceneOpacity
        context.fill(
            bloom,
            with: .radialGradient(
                Gradient(colors: [palette.accent.color.opacity(0.16), palette.accent.color.opacity(0)]),
                center: center,
                startRadius: 0,
                endRadius: bloomRadius
            )
        )
    }

    /// Each glyph's character is resolved fresh every frame as the texture
    /// rolls over the sphere. Resolving the atlas once up front keeps the
    /// varied character field inexpensive to draw.
    private func drawGlobe(
        in context: inout GraphicsContext,
        center: CGPoint,
        glyphs: [GlobeGlyph],
        spacing: CGFloat,
        elapsed: TimeInterval,
        sceneOpacity: Double
    ) {
        let phase = elapsed * AsciiGlobeMetrics.rotationSpeed
        let levels = AsciiGlobe.charset.map { char in
            context.resolve(
                Text(char)
                    .font(AsciiGlobeMetrics.glyphFont(for: spacing))
                    .foregroundColor(palette.accent.color)
            )
        }

        for glyph in glyphs {
            let shade = glyph.shade(phase: phase)
            let level = glyph.characterLevel(phase: phase, count: levels.count)
            context.opacity = sceneOpacity * (0.16 + shade * 0.84)
            context.draw(
                levels[level],
                at: CGPoint(x: center.x + glyph.offset.x, y: center.y + glyph.offset.y)
            )
        }
    }

}

// MARK: - Globe texture

/// A single glyph's fixed position on the sphere, precomputed once — only
/// its *shade* (and therefore which character represents it) changes frame
/// to frame as the globe spins.
private struct GlobeGlyph {
    let offset: CGPoint
    let depth: Double
    let dxNormalized: Double
    let latitude: Double

    /// `phase` rotates the texture's longitude, which is what reads as the
    /// sphere spinning even though every glyph stays put on screen — only
    /// the character drawn at each position changes.
    func shade(phase: Double) -> Double {
        let longitude = atan2(dxNormalized, depth) + phase
        let pattern = 0.5 + 0.5 * sin(longitude * 3 + latitude * 3.2)
        let lit = depth * 0.55 - latitude * 0.25
        return (pattern * 0.5 + lit * 0.5).clampedToUnit
    }

    /// A stable, travelling character field gives the surface its own
    /// typographic texture. This deliberately uses several glyph families
    /// (dots, symbols, numerals, and dense marks), rather than making the
    /// whole sphere a single repeated character at each brightness level.
    func characterLevel(phase: Double, count: Int) -> Int {
        let longitude = atan2(dxNormalized, depth) + phase
        let bands = sin(longitude * 2.4 + latitude * 7.2)
        let grain = sin(longitude * 6.8 - latitude * 4.1)
        let value = ((bands * 0.7 + grain * 0.3) + 1) / 2
        return min(count - 1, max(0, Int(value * Double(count))))
    }
}

private enum AsciiGlobe {
    /// The reference globe is a field of distinct keyboard characters, not
    /// a dot matrix. Keep the set compact enough to read as texture, but use
    /// visibly different marks from sparse to dense.
    static let charset = ["·", ".", ":", "+", "*", "%", "&", "0", "#", "@"]

    static func glyphs(radius: CGFloat, spacing: CGFloat) -> [GlobeGlyph] {
        var result: [GlobeGlyph] = []

        var y = -radius
        while y <= radius {
            var x = -radius
            while x <= radius {
                defer { x += spacing }
                let r = (x * x + y * y).squareRoot() / radius
                guard r <= 1 else { continue }
                let depth = max(0, 1 - r * r).squareRoot()
                result.append(GlobeGlyph(
                    offset: CGPoint(x: x, y: y),
                    depth: depth,
                    dxNormalized: x / radius,
                    latitude: y / radius
                ))
            }
            y += spacing
        }
        return result
    }
}

// MARK: - Timing

private enum AsciiGlobeMetrics {
    /// The radius glyph spacing is authored against, so density stays
    /// constant as the globe grows rather than spreading thin.
    static let referenceRadius: CGFloat = 132
    static let rotationSpeed: Double = 0.55
    /// Smooth, near-display-rate motion for the spin — the glyph texture
    /// itself reads as "text" regardless of frame rate, so there's no reason
    /// to cap this the way a genuinely retro effect would.
    static let frameInterval: TimeInterval = 1.0 / 30.0

    /// The globe fills most of the screen's shorter dimension, leaving just
    /// enough margin that the bloom doesn't clip at the edges.
    static func radius(for size: CGSize) -> CGFloat {
        min(size.width, size.height) * 0.46
    }

    /// Spacing scales with radius so glyph density — and therefore the
    /// texture's character — stays constant as the globe grows, rather than
    /// the glyphs spreading thin or the draw count exploding.
    static func spacing(for radius: CGFloat) -> CGFloat {
        radius * (6.0 / referenceRadius)
    }

    static func glyphFont(for spacing: CGFloat) -> Font {
        .system(size: spacing * 1.5, weight: .semibold, design: .monospaced)
    }

    private static let entranceDuration: TimeInterval = 0.3
    private static let fadeStartsAt = LaunchIntroChoreography.videoFadeStartsAt
    private static let totalDuration = LaunchIntroChoreography.videoDuration

    static func sceneOpacity(elapsed: TimeInterval) -> Double {
        let entrance = (elapsed / entranceDuration).clampedToUnit
        let exit = elapsed <= fadeStartsAt
            ? 1
            : 1 - ((elapsed - fadeStartsAt) / (totalDuration - fadeStartsAt)).clampedToUnit
        return min(entrance, exit)
    }
}

private extension Double {
    var clampedToUnit: Double { max(0, min(1, self)) }
}
