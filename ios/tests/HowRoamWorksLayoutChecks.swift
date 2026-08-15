import Foundation

@main
struct HowRoamWorksLayoutChecks {
    static func main() {
        expect(
            HowRoamWorksLayoutSpec.sectionSpacing > HowRoamWorksLayoutSpec.titleContentSpacing,
            "separate topics need more breathing room than a title and its content"
        )
        expect(
            HowRoamWorksLayoutSpec.rowVerticalPadding >= 10,
            "explanation rows need consistent scan-friendly vertical padding"
        )
        expect(
            HowRoamWorksLayoutSpec.entryRowVerticalPadding >= 12,
            "the home entry row must feel comfortably tappable rather than cramped"
        )
        expect(
            HowRoamWorksLayoutSpec.topPadding >= 16,
            "sheet content must clear the compact navigation bar"
        )
        expect(
            HowRoamWorksLayoutSpec.bottomPadding >= 40,
            "the final limits card must clear the home indicator comfortably"
        )
        expect(
            HowRoamWorksLayoutSpec.maximumContentWidth <= 680,
            "long explanations should not stretch edge-to-edge on iPad"
        )

        print("How Roam works layout checks passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError("How Roam works layout check failed: \(message)")
        }
    }
}
