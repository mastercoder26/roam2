import Foundation

@main
struct PremiumMotionChecks {
    static func main() {
        slicedWordmarkCoversEveryGlyphBand()
        slicedWordmarkResolvesWithoutLosingItsIdentity()
        kineticMetricsStayLegibleAndPurposeful()
        focusTransitionsStayInsideTheMotionBudget()

        print("Premium motion checks passed")
    }

    private static func slicedWordmarkCoversEveryGlyphBand() {
        let slices = PremiumMotionSpec.wordmarkSlices
        expect(slices.count >= 4, "the wordmark needs enough bands to read as deliberately sliced")
        expect(nearlyEqual(slices.first?.lowerBound ?? -1, 0), "the first wordmark band must start at the top")
        expect(nearlyEqual(slices.last?.upperBound ?? -1, 1), "the final wordmark band must reach the baseline")

        for (left, right) in zip(slices, slices.dropFirst()) {
            expect(left.lowerBound < left.upperBound, "every wordmark slice must have positive height")
            expect(nearlyEqual(left.upperBound, right.lowerBound), "wordmark slices must not leave seams or overlap")
        }

        expect(
            slices.allSatisfy { abs($0.settledOffsetFactor) <= 0.03 },
            "the settled glitch must remain subtle enough for the wordmark to read instantly"
        )
    }

    private static func slicedWordmarkResolvesWithoutLosingItsIdentity() {
        for slice in PremiumMotionSpec.wordmarkSlices {
            let entering = PremiumMotionSpec.wordmarkOffsetFactor(
                for: slice,
                progress: 0,
                reduceMotion: false
            )
            let settled = PremiumMotionSpec.wordmarkOffsetFactor(
                for: slice,
                progress: 1,
                reduceMotion: false
            )
            let reduced = PremiumMotionSpec.wordmarkOffsetFactor(
                for: slice,
                progress: 0,
                reduceMotion: true
            )

            expect(abs(entering) >= abs(settled), "launch slices should resolve inward, never spread farther apart")
            expect(nearlyEqual(settled, slice.settledOffsetFactor), "the animated mark must land on the static header mark")
            expect(nearlyEqual(reduced, settled), "Reduce Motion must skip slice travel")
        }
    }

    private static func kineticMetricsStayLegibleAndPurposeful() {
        expect(PremiumMotionSpec.heroMetric.maximumBlur <= 2, "hero numeral blur must stay crisp")
        expect(
            !PremiumMotionSpec.allowsKineticTreatment(in: .activeDrive),
            "live driving values must remain visually stable"
        )
        expect(PremiumMotionSpec.heroMetric.settleDuration < 0.3, "hero metric UI motion must remain under 300ms")
        expect(PremiumMotionSpec.allowsKineticTreatment(in: .routeResult), "a rare route result may use the hero treatment")
        expect(PremiumMotionSpec.allowsKineticTreatment(in: .completedDrive), "a completed drive may use the hero treatment")
    }

    private static func focusTransitionsStayInsideTheMotionBudget() {
        expect(PremiumMotionSpec.focusTransition.blurRadius <= 8, "focus transitions must not use expensive blur")
        expect(PremiumMotionSpec.focusTransition.scale >= 0.97, "content must not appear from an implausibly small scale")
        expect(PremiumMotionSpec.focusTransition.duration < 0.3, "focus transitions must remain responsive")
        expect(PremiumMotionSpec.reducedFocusTransition.blurRadius == 0, "Reduce Motion must remove blur")
        expect(PremiumMotionSpec.reducedFocusTransition.verticalOffset == 0, "Reduce Motion must remove travel")
    }

    private static func nearlyEqual(_ lhs: Double, _ rhs: Double, tolerance: Double = 0.000_001) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError("Premium motion check failed: \(message)")
        }
    }
}
