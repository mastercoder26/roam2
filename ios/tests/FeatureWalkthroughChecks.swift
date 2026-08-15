import Foundation

@main
struct FeatureWalkthroughChecks {
    static func main() {
        theWalkthroughExplainsTheWholeRoamJourney()
        theProgressModelClampsAndFinishesPredictably()
        everyStepHasAccessibleVisibleCopy()

        print("Feature walkthrough checks passed")
    }

    private static func theWalkthroughExplainsTheWholeRoamJourney() {
        expect(
            FeatureWalkthroughStep.allCases == [.plan, .understand, .drive, .grow],
            "the walkthrough should follow the product journey from planning through growth"
        )
        expect(
            FeatureWalkthroughStep.plan.title == "Plan with context",
            "the first step should introduce route planning"
        )
        expect(
            FeatureWalkthroughStep.grow.actionTitle == "Start exploring",
            "the final step should finish with a clear return-to-app action"
        )
    }

    private static func theProgressModelClampsAndFinishesPredictably() {
        expect(
            FeatureWalkthroughStep.step(at: -1) == .plan,
            "a negative index should stay on the first step"
        )
        expect(
            FeatureWalkthroughStep.step(at: 99) == .grow,
            "an overrun index should remain on the final step"
        )
        expect(
            FeatureWalkthroughStep.plan.progressLabel == "1 of 4",
            "the first step should announce its position"
        )
        expect(
            FeatureWalkthroughStep.grow.progressLabel == "4 of 4",
            "the final step should announce its position"
        )
    }

    private static func everyStepHasAccessibleVisibleCopy() {
        for step in FeatureWalkthroughStep.allCases {
            expect(!step.title.isEmpty, "each step needs a title")
            expect(!step.detail.isEmpty, "each step needs explanatory detail")
            expect(!step.symbol.isEmpty, "each step needs a recognizable symbol")
            expect(!step.actionTitle.isEmpty, "each step needs an action")
        }

        let fullStory = FeatureWalkthroughStep.allCases
            .map { "\($0.title) \($0.detail)" }
            .joined(separator: " ")
        for feature in ["Routes", "Drive", "Progress", "Profile"] {
            expect(fullStory.contains(feature), "the guide should name the \(feature) feature")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError("Feature walkthrough check failed: \(message)")
        }
    }
}
