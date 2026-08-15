import Foundation

/// A point in the intro's authored design canvas. Deliberately not `CGPoint`
/// so the whole choreography stays Foundation-only and can be checked from the
/// command line alongside the scoring engines.
struct IntroPoint: Equatable {
    let x: Double
    let y: Double
}

/// Geometry and timing for the launch intro.
///
/// The intro tells Roam's one-sentence story in under two seconds: a road is
/// drawn, the waypoints along it light up as the drive passes them, and the
/// headlight sweeping off the end of that road is what reveals the wordmark.
/// Keeping the curve and the beat times here means the sequence can be tuned
/// and verified without launching a simulator.
enum LaunchIntroChoreography {
    // MARK: - Geometry

    /// The canvas the road is authored in. The view scales this to fit the
    /// device rather than re-authoring control points per screen size.
    static let canvasWidth: Double = 300
    static let canvasHeight: Double = 132

    static let start = IntroPoint(x: 14, y: 104)
    static let control1 = IntroPoint(x: 78, y: 10)
    static let control2 = IntroPoint(x: 214, y: 148)
    static let end = IntroPoint(x: 286, y: 42)

    /// Waypoints that light up as the trace passes them. They are the reason
    /// the road reads as a *measured* route rather than a decorative squiggle.
    static let milestones: [Double] = [0.16, 0.40, 0.64, 0.88]

    /// Length of the comet trail behind the travelling head, as a fraction of
    /// the curve. Short enough to read as motion blur, not as a second stroke.
    static let trailLength: Double = 0.14

    /// Position on the road at `t` in 0...1.
    static func point(at t: Double) -> IntroPoint {
        let clamped = t.clampedToUnit
        let inverse = 1 - clamped

        func channel(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double) -> Double {
            inverse * inverse * inverse * p0
                + 3 * inverse * inverse * clamped * p1
                + 3 * inverse * clamped * clamped * p2
                + clamped * clamped * clamped * p3
        }

        return IntroPoint(
            x: channel(start.x, control1.x, control2.x, end.x),
            y: channel(start.y, control1.y, control2.y, end.y)
        )
    }

    /// Travel direction at `t`, in degrees, for orienting the head marker.
    static func headingDegrees(at t: Double) -> Double {
        let clamped = t.clampedToUnit
        let inverse = 1 - clamped

        func derivative(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double) -> Double {
            3 * inverse * inverse * (p1 - p0)
                + 6 * inverse * clamped * (p2 - p1)
                + 3 * clamped * clamped * (p3 - p2)
        }

        let dx = derivative(start.x, control1.x, control2.x, end.x)
        let dy = derivative(start.y, control1.y, control2.y, end.y)
        guard dx != 0 || dy != 0 else { return 0 }
        return atan2(dy, dx) * 180 / .pi
    }

    /// The start of the comet trail for a head at `progress`.
    static func trailStart(for progress: Double) -> Double {
        max(0, progress.clampedToUnit - trailLength)
    }

    static func isMilestoneLit(_ fraction: Double, traceProgress: Double) -> Bool {
        traceProgress.clampedToUnit >= fraction
    }

    // MARK: - Timing

    /// The road drawing itself.
    static let traceDuration: TimeInterval = 0.78
    /// The headlight sweep starts before the road finishes, so the two beats
    /// overlap instead of the viewer waiting through a dead gap.
    static let revealDelay: TimeInterval = 0.52
    static let revealDuration: TimeInterval = 0.62
    /// A short beat on the finished lockup before it hands off to the app.
    static let holdDuration: TimeInterval = 0.24
    static let exitDuration: TimeInterval = 0.32

    static var totalDuration: TimeInterval {
        revealDelay + revealDuration + holdDuration + exitDuration
    }

    /// Reduce Motion gets the same lockup with no travel: a plain fade, held
    /// just long enough to read, then the same handoff.
    static let reducedFadeDuration: TimeInterval = 0.24
    static let reducedHoldDuration: TimeInterval = 0.36

    static var reducedTotalDuration: TimeInterval {
        reducedFadeDuration + reducedHoldDuration + exitDuration
    }

    static func totalDuration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? reducedTotalDuration : totalDuration
    }

    /// Time away from the app after which reopening replays the intro. Short
    /// app switches should not re-run it, which is what "every launch" means
    /// in practice on a phone that rarely fully quits an app.
    static let replayThreshold: TimeInterval = 180

    /// The intro covers the whole screen, so it must never interrupt an active
    /// drive on return from the background.
    static func shouldReplay(awayFor interval: TimeInterval, isRecording: Bool) -> Bool {
        guard !isRecording else { return false }
        return interval >= replayThreshold
    }

    // MARK: - Headlight sweep

    /// Leading and trailing edge of the sweep band that lights the wordmark,
    /// as mask locations in 0...1. The band travels past the right edge so it
    /// exits cleanly and leaves the wordmark fully lit.
    static let sweepOvershoot: Double = 1.30
    static let sweepBandWidth: Double = 0.26

    static func sweepEdges(progress: Double) -> (trailing: Double, leading: Double) {
        // Both edges are clamped from the same unclamped travel, so the band
        // keeps moving after its leading edge has left the wordmark and the
        // trail catches up to fully light it.
        let travelled = progress * sweepOvershoot
        return (
            trailing: (travelled - sweepBandWidth).clampedToUnit,
            leading: travelled.clampedToUnit
        )
    }

    // MARK: - Shine

    /// A second, narrower specular pass over the wordmark once the headlight
    /// sweep has fully lit it — the glint that makes the reveal read as
    /// polished metal rather than a flat fill. Starts the moment the sweep's
    /// own reveal animation completes.
    static let shineDelay: TimeInterval = revealDelay + revealDuration
    static let shineDuration: TimeInterval = 0.45

    // MARK: - Video wordmark overlay

    /// The clip's own timing, mirrored from `tools/intro-render/capture.mjs`.
    /// The wordmark beats are placed against it: the mark arrives while the
    /// globe is fully lit, and finishes docking as the clip fades to canvas.
    static let videoDuration: TimeInterval = 2.4
    static let videoGlobeSettledAt: TimeInterval = 0.34
    static let videoFadeStartsAt: TimeInterval = 2.02

    /// How long after the globe clip starts before the wordmark fades in
    /// above it, large and centered.
    static let videoWordmarkDelay: TimeInterval = 0.6
    static let videoWordmarkFadeDuration: TimeInterval = 0.45
    /// A beat at hero size, so the big mark reads before it moves.
    static let wordmarkHeroHoldDuration: TimeInterval = 0.45
    /// The glide from above-the-globe to the top-left corner it occupies
    /// everywhere else in the app.
    static let wordmarkDockDuration: TimeInterval = 0.7
    /// A short beat with the docked wordmark alone on the now-solid canvas
    /// before handing off, so it reads rather than flashing past.
    static let videoWordmarkHoldDuration: TimeInterval = 0.5

    /// When the dock glide begins, measured from the start of the clip.
    static var wordmarkDockDelay: TimeInterval {
        videoWordmarkDelay + videoWordmarkFadeDuration + wordmarkHeroHoldDuration
    }

    // MARK: - Wordmark placement

    /// The mark is *drawn* at hero size and scaled down to dock, never up.
    /// Rasterizing at the larger of the two sizes is what keeps the docked
    /// mark crisp, and scaling a fixed raster is what keeps the glide smooth —
    /// re-laying out text at a new size every frame is not.
    static let wordmarkHeroFontSize: Double = 72
    /// Matches `BrandWordmark(compact:)`, so the mark lands at exactly the
    /// size the app's own header wears.
    static let wordmarkDockedFontSize: Double = 23
    static var wordmarkDockedScale: Double { wordmarkDockedFontSize / wordmarkHeroFontSize }

    /// Where the docked mark sits, inset from the safe area's top left — the
    /// same inset the app's header uses.
    static let wordmarkDockedInset = IntroPoint(x: 24, y: 20)
    /// Vertical placement of the hero mark, as a fraction of screen height.
    /// High enough to sit clear above the centered globe.
    static let wordmarkHeroTopFraction: Double = 0.12

    /// Top-left origin of the wordmark for the current phase. `wordmarkWidth`
    /// is the mark's width as drawn — i.e. at hero size — and scaling is
    /// anchored at the same top-left corner this origin places.
    ///
    /// `measuredDockedTarget`, when supplied, is the real header wordmark's
    /// on-screen frame (read live via a preference from `RoamRootView`, which
    /// sits behind the intro the whole time) — so the docked mark lands in
    /// its exact usual spot instead of an inset that has to be kept in sync
    /// by hand whenever the header's own padding changes.
    static func wordmarkOrigin(
        docked: Bool,
        screenWidth: Double,
        screenHeight: Double,
        wordmarkWidth: Double,
        measuredDockedTarget: IntroPoint? = nil
    ) -> IntroPoint {
        guard !docked else { return measuredDockedTarget ?? wordmarkDockedInset }

        return IntroPoint(
            x: max(wordmarkDockedInset.x, (screenWidth - wordmarkWidth) / 2),
            y: screenHeight * wordmarkHeroTopFraction
        )
    }
}

private extension Double {
    var clampedToUnit: Double { max(0, min(1, self)) }
}
