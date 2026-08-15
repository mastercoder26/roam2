import Foundation

@main
struct LaunchIntroChoreographyChecks {
    static func main() {
        theRoadStartsAndEndsWhereItIsAuthored()
        theRoadAlwaysTravelsForward()
        theHeadPointsAlongTheDirectionOfTravel()
        theCometTrailNeverRunsOffTheStartOfTheRoad()
        waypointsLightUpOnlyOnceThePassIsMade()
        theSweepBandStaysOrderedAndInsideItsMask()
        theWholeSequenceStaysShortEnoughToNotAnnoy()
        aReturningDriverOnlySeesItAfterARealAbsence()
        theWordmarkIsBigAndCenteredBeforeItDocks()
        theNoPathGlobeRevealKeepsItsVisualBeatsOrdered()

        print("Launch intro choreography checks passed")
    }

    private static func theRoadStartsAndEndsWhereItIsAuthored() {
        expect(
            LaunchIntroChoreography.point(at: 0) == LaunchIntroChoreography.start,
            "the trace must begin at the authored start point"
        )
        expect(
            LaunchIntroChoreography.point(at: 1) == LaunchIntroChoreography.end,
            "the trace must finish at the authored end point"
        )
        expect(
            LaunchIntroChoreography.point(at: 2) == LaunchIntroChoreography.end,
            "an over-run progress value must clamp instead of flying off canvas"
        )
        expect(
            LaunchIntroChoreography.point(at: -1) == LaunchIntroChoreography.start,
            "a negative progress value must clamp to the start"
        )
    }

    private static func theRoadAlwaysTravelsForward() {
        // A backward step would read as the light stuttering rather than driving.
        var previousX = LaunchIntroChoreography.point(at: 0).x
        for step in 1...40 {
            let x = LaunchIntroChoreography.point(at: Double(step) / 40).x
            expect(x > previousX, "the road must advance left to right at every step")
            previousX = x
        }

        let everyPointOnCanvas = (0...40).allSatisfy { step in
            let point = LaunchIntroChoreography.point(at: Double(step) / 40)
            return point.x >= 0
                && point.x <= LaunchIntroChoreography.canvasWidth
                && point.y >= 0
                && point.y <= LaunchIntroChoreography.canvasHeight
        }
        expect(everyPointOnCanvas, "the road must stay inside the authored canvas")
    }

    private static func theHeadPointsAlongTheDirectionOfTravel() {
        expect(
            LaunchIntroChoreography.headingDegrees(at: 0) < 0,
            "the head should be climbing as it leaves the start"
        )
        expect(
            LaunchIntroChoreography.headingDegrees(at: 1) < 0,
            "the head should be climbing again as it reaches the end"
        )
        expect(
            LaunchIntroChoreography.headingDegrees(at: 0.5) > 0,
            "the head should be descending through the middle dip"
        )
    }

    private static func theCometTrailNeverRunsOffTheStartOfTheRoad() {
        expect(
            LaunchIntroChoreography.trailStart(for: 0.05) == 0,
            "an early trail must clamp to the start rather than trim negatively"
        )
        expect(
            nearlyEqual(
                LaunchIntroChoreography.trailStart(for: 0.9),
                0.9 - LaunchIntroChoreography.trailLength
            ),
            "a mid-road trail must sit one trail length behind the head"
        )
        expect(
            LaunchIntroChoreography.trailStart(for: 1) < 1,
            "the trail must remain a visible segment at the end of the road"
        )
    }

    private static func waypointsLightUpOnlyOnceThePassIsMade() {
        let first = LaunchIntroChoreography.milestones[0]
        expect(
            !LaunchIntroChoreography.isMilestoneLit(first, traceProgress: 0),
            "no waypoint is lit before the drive starts"
        )
        expect(
            LaunchIntroChoreography.isMilestoneLit(first, traceProgress: first),
            "a waypoint lights the moment the head reaches it"
        )
        expect(
            LaunchIntroChoreography.milestones.allSatisfy {
                LaunchIntroChoreography.isMilestoneLit($0, traceProgress: 1)
            },
            "every waypoint is lit once the road is complete"
        )
        expect(
            LaunchIntroChoreography.milestones == LaunchIntroChoreography.milestones.sorted(),
            "waypoints must be authored in travel order"
        )
    }

    private static func theSweepBandStaysOrderedAndInsideItsMask() {
        for step in 0...20 {
            let edges = LaunchIntroChoreography.sweepEdges(progress: Double(step) / 20)
            expect(edges.trailing >= 0, "a gradient stop must not sit before its mask")
            expect(edges.leading <= 1, "a gradient stop must not sit past its mask")
            expect(
                edges.trailing <= edges.leading,
                "gradient stops must stay in ascending order or the mask inverts"
            )
        }

        expect(
            LaunchIntroChoreography.sweepEdges(progress: 1).trailing == 1,
            "the finished sweep must leave the wordmark fully lit"
        )
    }

    private static func theWholeSequenceStaysShortEnoughToNotAnnoy() {
        expect(
            LaunchIntroChoreography.totalDuration < 2,
            "a launch intro seen on every open must stay under two seconds"
        )
        expect(
            LaunchIntroChoreography.revealDelay < LaunchIntroChoreography.traceDuration,
            "the wordmark sweep must overlap the road trace rather than wait for it"
        )
        expect(
            LaunchIntroChoreography.totalDuration
                > LaunchIntroChoreography.traceDuration + LaunchIntroChoreography.exitDuration,
            "the road must finish drawing before the intro hands off"
        )
        expect(
            LaunchIntroChoreography.reducedTotalDuration < LaunchIntroChoreography.totalDuration,
            "Reduce Motion must get the shorter, still-legible version"
        )
        expect(
            LaunchIntroChoreography.totalDuration(reduceMotion: true)
                == LaunchIntroChoreography.reducedTotalDuration,
            "the reduced duration must be what the view schedules its handoff on"
        )
    }

    private static func aReturningDriverOnlySeesItAfterARealAbsence() {
        expect(
            !LaunchIntroChoreography.shouldReplay(awayFor: 5, isRecording: false),
            "a glance at the task switcher must not replay the intro"
        )
        expect(
            LaunchIntroChoreography.shouldReplay(
                awayFor: LaunchIntroChoreography.replayThreshold,
                isRecording: false
            ),
            "returning after a real absence should replay the intro"
        )
        expect(
            !LaunchIntroChoreography.shouldReplay(awayFor: 3_600, isRecording: true),
            "a recorded drive must never be covered by the intro"
        )
    }

    private static func theWordmarkIsBigAndCenteredBeforeItDocks() {
        let screenWidth = 390.0
        let screenHeight = 844.0
        // The mark is drawn at hero size, so its measured width is already the
        // width the centering has to work with.
        let markWidth = 210.0

        let hero = LaunchIntroChoreography.wordmarkOrigin(
            docked: false,
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            wordmarkWidth: markWidth
        )
        expect(
            nearlyEqual(hero.x + markWidth / 2, screenWidth / 2),
            "the hero wordmark must be optically centered on screen"
        )
        expect(
            hero.y < screenHeight / 2 - 40,
            "the hero wordmark must sit clear above the centered globe"
        )
        expect(
            LaunchIntroChoreography.wordmarkDockedScale < 0.5,
            "the hero wordmark must be markedly bigger than the docked one"
        )
        expect(
            nearlyEqual(
                LaunchIntroChoreography.wordmarkHeroFontSize
                    * LaunchIntroChoreography.wordmarkDockedScale,
                LaunchIntroChoreography.wordmarkDockedFontSize
            ),
            "the docked mark must land at exactly the app header's wordmark size"
        )
        expect(
            LaunchIntroChoreography.wordmarkDockedScale < 1,
            "the mark must be scaled down to dock, never blown up from a small raster"
        )

        let docked = LaunchIntroChoreography.wordmarkOrigin(
            docked: true,
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            wordmarkWidth: markWidth
        )
        expect(
            docked == LaunchIntroChoreography.wordmarkDockedInset,
            "the docked wordmark must land on the app's own top-left inset"
        )
        expect(docked.y < hero.y, "the wordmark must travel upward as it docks")

        // A mark too wide to center must still clear the left safe-area inset
        // rather than sliding off the edge of a narrow screen.
        let oversized = LaunchIntroChoreography.wordmarkOrigin(
            docked: false,
            screenWidth: 320,
            screenHeight: screenHeight,
            wordmarkWidth: 400
        )
        expect(
            oversized.x >= LaunchIntroChoreography.wordmarkDockedInset.x,
            "an oversized hero wordmark must not be pushed off the left edge"
        )
    }

    /// The globe and wordmark are the complete intro. Keeping these beats
    /// contiguous prevents a route, flight, or other path animation from
    /// being inserted between the globe reveal and the brand handoff.
    private static func theNoPathGlobeRevealKeepsItsVisualBeatsOrdered() {
        expect(
            LaunchIntroChoreography.videoWordmarkDelay
                > LaunchIntroChoreography.videoGlobeSettledAt,
            "the globe must fully settle before the wordmark begins"
        )
        expect(
            LaunchIntroChoreography.videoFadeStartsAt
                > LaunchIntroChoreography.wordmarkDockDelay,
            "the globe must not begin fading until the wordmark starts docking"
        )
        expect(
            LaunchIntroChoreography.wordmarkDockDelay
                + LaunchIntroChoreography.wordmarkDockDuration
                < LaunchIntroChoreography.videoDuration,
            "the globe duration must leave the docked wordmark visible before handoff"
        )
    }

    private static func nearlyEqual(_ lhs: Double, _ rhs: Double, tolerance: Double = 0.0001) -> Bool {
        abs(lhs - rhs) < tolerance
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError("Launch intro choreography check failed: \(message)")
        }
    }
}
