import CoreGraphics

/// Shared width thresholds for layouts that otherwise contain fixed-size,
/// horizontal controls. Keeping the decisions here makes compact-phone and
/// large-text behavior deterministic and straightforward to regression-test.
enum LayoutResponsiveness {
    private static let stackedControlThreshold: CGFloat = 320
    private static let stackedDashboardThreshold: CGFloat = 340
    private static let maximumLoadingSceneWidth: CGFloat = 320

    static func stacksInlineControls(availableWidth: CGFloat, usesLargeText: Bool) -> Bool {
        usesLargeText || availableWidth < stackedControlThreshold
    }

    static func usesCompactRoutePlanningTitle(usesLargeText: Bool) -> Bool {
        usesLargeText
    }

    static func loadingSceneWidth(availableWidth: CGFloat, horizontalPadding: CGFloat) -> CGFloat {
        min(maximumLoadingSceneWidth, max(0, availableWidth - (horizontalPadding * 2)))
    }

    static func stacksDashboardMetrics(availableWidth: CGFloat, usesLargeText: Bool) -> Bool {
        usesLargeText || availableWidth < stackedDashboardThreshold
    }
}
