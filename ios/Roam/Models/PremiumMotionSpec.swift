import Foundation

struct WordmarkSliceSpec: Equatable {
    let lowerBound: Double
    let upperBound: Double
    let settledOffsetFactor: Double
    let enteringOffsetFactor: Double
}

struct MetricMotionSpec: Equatable {
    let reflectionOpacity: Double
    let maximumBlur: Double
    let settleDuration: TimeInterval
}

struct FocusTransitionSpec: Equatable {
    let opacity: Double
    let scale: Double
    let verticalOffset: Double
    let blurRadius: Double
    let duration: TimeInterval
}

enum KineticMetricContext: Equatable {
    case routeResult
    case completedDrive
    case activeDrive
}

/// Pure design parameters for Roam's authored motion language. Keeping the
/// constraints Foundation-only makes the motion budget testable without a
/// simulator and prevents one-off effects from drifting across screens.
enum PremiumMotionSpec {
    static let wordmarkSlices: [WordmarkSliceSpec] = [
        WordmarkSliceSpec(lowerBound: 0, upperBound: 0.24, settledOffsetFactor: -0.012, enteringOffsetFactor: -0.08),
        WordmarkSliceSpec(lowerBound: 0.24, upperBound: 0.49, settledOffsetFactor: 0.022, enteringOffsetFactor: 0.07),
        WordmarkSliceSpec(lowerBound: 0.49, upperBound: 0.73, settledOffsetFactor: -0.018, enteringOffsetFactor: -0.065),
        WordmarkSliceSpec(lowerBound: 0.73, upperBound: 1, settledOffsetFactor: 0.009, enteringOffsetFactor: 0.055)
    ]

    static let heroMetric = MetricMotionSpec(
        reflectionOpacity: 0.14,
        maximumBlur: 2,
        settleDuration: 0.26
    )

    static let focusTransition = FocusTransitionSpec(
        opacity: 0,
        scale: 0.975,
        verticalOffset: 10,
        blurRadius: 8,
        duration: 0.26
    )

    static let reducedFocusTransition = FocusTransitionSpec(
        opacity: 0,
        scale: 1,
        verticalOffset: 0,
        blurRadius: 0,
        duration: 0.18
    )

    static func wordmarkOffsetFactor(
        for slice: WordmarkSliceSpec,
        progress: Double,
        reduceMotion: Bool
    ) -> Double {
        guard !reduceMotion else { return slice.settledOffsetFactor }
        let clamped = max(0, min(1, progress))
        return slice.enteringOffsetFactor
            + (slice.settledOffsetFactor - slice.enteringOffsetFactor) * clamped
    }

    static func allowsKineticTreatment(in context: KineticMetricContext) -> Bool {
        switch context {
        case .routeResult, .completedDrive:
            true
        case .activeDrive:
            false
        }
    }
}
