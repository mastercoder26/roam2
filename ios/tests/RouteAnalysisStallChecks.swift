import Foundation

/// Regression checks for the "stuck on Analyzing route difficulty" report.
///
/// Two independent defects produced that symptom: a `.pending` analysis that
/// nothing could ever complete, and a post-drive banner that was never retired
/// once the analysis resolved. Both are pure logic and are pinned here.
@main
struct RouteAnalysisStallChecks {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        aPendingAnalysisWithRetriesLeftIsNotStalled()
        aPendingAnalysisOutOfRetriesIsStalled()
        aResolvedAnalysisIsNeverStalled()
        anInFlightAnalysisLeavesTheBannerAlone()
        aSuccessfulAnalysisRetiresTheAnalyzingBanner()
        aFailedAnalysisRetiresTheAnalyzingBanner()

        print("Route analysis stall checks passed")
    }

    /// The normal case: a freshly saved drive is pending because a request is
    /// genuinely in flight, and must not be prematurely marked unavailable.
    private static func aPendingAnalysisWithRetriesLeftIsNotStalled() {
        expect(
            !DriveRouteAnalysis.pending.isStalled(),
            "a pending analysis that can still retry is in flight, not stalled"
        )
    }

    /// Every retry spent while the status is still `.pending` means the app was
    /// killed mid-request each time. Nothing will complete it, so the drive
    /// would otherwise spin "Analyzing route" forever.
    private static func aPendingAnalysisOutOfRetriesIsStalled() {
        var analysis = DriveRouteAnalysis.pending
        for _ in 0..<4 {
            analysis = analysis.recordingAttempt()
        }

        expect(analysis.status == .pending, "the drive is still marked pending after four interrupted attempts")
        expect(!analysis.shouldRetry(), "the retry budget is spent, so nothing will restart the request")
        expect(analysis.isStalled(), "a pending analysis nothing can complete must be reported as stalled")
    }

    private static func aResolvedAnalysisIsNeverStalled() {
        let available = DriveRouteAnalysis.available(
            difficultyScore: 6.2,
            label: .moderate,
            highlights: [],
            analyzedAt: Date()
        )
        let exhausted = DriveRouteAnalysis.unavailable("no network", retryEligible: false, retryCount: 4)

        expect(!available.isStalled(), "a completed analysis is resolved, not stalled")
        expect(!exhausted.isStalled(), "an unavailable analysis already shows a final state")
    }

    private static func anInFlightAnalysisLeavesTheBannerAlone() {
        expect(
            DriveStatusMessageEngine.resolvedMessage(for: .pending) == nil,
            "a still-running analysis must not replace the banner"
        )
    }

    /// The reported bug: the banner said "Analyzing route difficulty" and was
    /// never replaced, so a drive whose analysis had already succeeded still
    /// read as analyzing.
    private static func aSuccessfulAnalysisRetiresTheAnalyzingBanner() {
        let analysis = DriveRouteAnalysis.available(
            difficultyScore: 7.4,
            label: .hard,
            highlights: [],
            analyzedAt: Date()
        )
        guard let message = DriveStatusMessageEngine.resolvedMessage(for: analysis) else {
            fail("a completed analysis must produce a banner that replaces the analyzing text")
        }

        expect(message != DriveStatusMessageEngine.analyzing, "the banner must stop saying it is analyzing")
        expect(message.contains("7.4"), "the resolved banner should report the difficulty it found")
    }

    private static func aFailedAnalysisRetiresTheAnalyzingBanner() {
        let analysis = DriveRouteAnalysis.unavailable("offline", retryEligible: true)
        guard let message = DriveStatusMessageEngine.resolvedMessage(for: analysis) else {
            fail("a failed analysis must still retire the analyzing banner")
        }

        expect(message != DriveStatusMessageEngine.analyzing, "a failure must not read as still analyzing")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        fatalError("Route analysis stall check failed: \(message)")
    }
}
