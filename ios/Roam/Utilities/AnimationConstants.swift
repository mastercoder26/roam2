import SwiftUI

/// Motion tokens aligned with Apple fluid-interface defaults:
/// critically damped springs for UI, snappy press feedback, no bounce on routine transitions.
enum AppAnimation {
    /// Default UI spring — no overshoot (damping 1.0, response 0.35)
    static let spring = Animation.spring(response: 0.35, dampingFraction: 1.0)

    /// Route-choice selection and compact control changes. This stays crisp
    /// enough for repeated taps without making the interface feel nervous.
    static let selection = Animation.spring(response: 0.30, dampingFraction: 1.0)

    /// A slightly slower, still critically damped transition for a new card
    /// or a meaningful summary becoming available.
    static let content = Animation.spring(response: 0.40, dampingFraction: 1.0)

    /// The manual-drive state change carries a timer upward and the primary
    /// action downward. It remains critically damped so it is calm and can be
    /// immediately reversed when a drive ends.
    static let driveMode = Animation.spring(response: 0.42, dampingFraction: 1.0)

    /// Deliberate reveal (score arc, breakdown bars)
    static let reveal = Animation.spring(response: 0.5, dampingFraction: 1.0)

    /// Hero section entrance on results screen
    static let hero = Animation.spring(response: 0.45, dampingFraction: 1.0)

    /// Button press, suggestion dismiss — must feel instant
    static let press = Animation.spring(response: 0.2, dampingFraction: 1.0)

    /// High-frequency UI (search suggestions, error fade)
    static let quick = Animation.easeOut(duration: 0.18)

    /// A strong ease-out for rare, high-salience content swaps. The incoming
    /// state resolves almost immediately, then settles without overshoot.
    static let focus = Animation.timingCurve(
        0.23,
        1,
        0.32,
        1,
        duration: PremiumMotionSpec.focusTransition.duration
    )

    /// Result numerals use a short odometer-style resolve. Kept separate from
    /// live drive motion so safety-critical values never inherit the effect.
    static let kineticMetric = Animation.timingCurve(
        0.23,
        1,
        0.32,
        1,
        duration: PremiumMotionSpec.heroMetric.settleDuration
    )

    /// The launch wordmark's slices pull into their permanent offsets once.
    static let wordmarkResolve = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.42)

    /// Route / map camera — on-screen movement
    static let mapDuration: TimeInterval = 0.28
    static let map = Animation.easeInOut(duration: mapDuration)

    /// Stagger between hero elements only (score → map)
    static let heroStagger: Double = 0.08

    /// A single split-flap card dropping. Short and slightly underdamped so the
    /// flap lands with a little weight instead of gliding, and always finishes
    /// well inside the one-second tick that triggers the next one.
    static let flip = Animation.spring(response: 0.26, dampingFraction: 0.72)

    /// The outgoing half of a split-flap tile lifting off the stack before it
    /// falls out of view. Real flap boards accelerate into this — a hinge
    /// letting go under its own weight — so it eases in rather than matching
    /// `flip`'s spring landing, and stays short enough that the two phases
    /// together still land well inside the one-second tick.
    static let flipLift = Animation.easeIn(duration: 0.13)
    static let flipLiftDuration: TimeInterval = 0.13

    /// Root tab switch — a plain crossfade, deliberately not a spring since the
    /// destination view is a whole screen swap rather than an in-place element.
    static let tabSwitch = Animation.easeOut(duration: 0.18)
    static let tabSwitchReduced = Animation.easeOut(duration: 0.12)

    /// The loading illustration's route tracing stroke and its exit "drive
    /// away" beat. Kept separate from `map`/`content` because both are tied to
    /// the hand-authored dot-car choreography, not general UI transitions.
    static let routeTrace = Animation.linear(duration: 0.64)
    static let departure = Animation.easeOut(duration: 0.30)
    static let departureReduced = Animation.easeOut(duration: 0.20)

    /// Swapping the drive surface's primary action label/icon in place —
    /// quicker and flatter than `quick` since it must not compete with the
    /// surrounding `driveMode` layout spring.
    static let actionSwap = Animation.easeInOut(duration: 0.12)
}
