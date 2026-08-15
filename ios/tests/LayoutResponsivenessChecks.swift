import CoreGraphics
import Foundation

@main
struct LayoutResponsivenessChecks {
    static func main() {
        inlineControlsStackForNarrowOrLargeTextLayouts()
        routePlanningTitleUsesItsCompactTextStyleAtAccessibilitySizes()
        loadingSceneNeverOutgrowsTheAvailableWidth()
        dashboardMetricsStackBeforeTheyBecomeUnreadable()

        print("Layout responsiveness checks passed")
    }

    // The tab bar compact-form check was removed alongside
    // LayoutResponsiveness.usesCompactTabBar in aa3fcc2, which reverted the
    // tab bar minimize behavior to .onScrollDown. The assertions outlived the
    // API they covered and had stopped compiling.

    private static func inlineControlsStackForNarrowOrLargeTextLayouts() {
        expect(
            LayoutResponsiveness.stacksInlineControls(availableWidth: 288, usesLargeText: false),
            "the break-plan selector must stack before its segmented control crowds its title"
        )
        expect(
            !LayoutResponsiveness.stacksInlineControls(availableWidth: 360, usesLargeText: false),
            "a regular-width control row should retain its compact horizontal presentation"
        )
        expect(
            LayoutResponsiveness.stacksInlineControls(availableWidth: 360, usesLargeText: true),
            "large Dynamic Type must use the vertical control arrangement"
        )
    }

    private static func routePlanningTitleUsesItsCompactTextStyleAtAccessibilitySizes() {
        expect(
            !LayoutResponsiveness.usesCompactRoutePlanningTitle(usesLargeText: false),
            "the normal route title should retain its high-emphasis style"
        )
        expect(
            LayoutResponsiveness.usesCompactRoutePlanningTitle(usesLargeText: true),
            "accessibility text should reserve vertical space for form controls rather than an oversized title"
        )
    }

    private static func loadingSceneNeverOutgrowsTheAvailableWidth() {
        let sceneWidth = LayoutResponsiveness.loadingSceneWidth(
            availableWidth: 320,
            horizontalPadding: 28
        )
        expect(
            sceneWidth == 264,
            "the loading illustration must account for the surrounding padding on narrow phones"
        )
        expect(
            LayoutResponsiveness.loadingSceneWidth(availableWidth: 430, horizontalPadding: 28) == 320,
            "the loading illustration should preserve its intended maximum size on regular phones"
        )
    }

    private static func dashboardMetricsStackBeforeTheyBecomeUnreadable() {
        expect(
            LayoutResponsiveness.stacksDashboardMetrics(availableWidth: 300, usesLargeText: false),
            "number-first dashboard metrics should stack on narrow phones"
        )
        expect(
            !LayoutResponsiveness.stacksDashboardMetrics(availableWidth: 390, usesLargeText: false),
            "dashboard metrics should retain their compact horizontal strip at regular widths"
        )
        expect(
            LayoutResponsiveness.stacksDashboardMetrics(availableWidth: 390, usesLargeText: true),
            "large Dynamic Type should stack dashboard metrics"
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError("Layout responsiveness check failed: \(message)")
        }
    }
}
