import SwiftUI
import UIKit

/// Coordinate space the launch intro and the real header share, so the
/// header's wordmark frame (captured via `HeaderWordmarkFrameKey`) can be
/// read directly as a docking target instead of an inset kept in sync by hand.
enum LaunchIntroDockSpace {
    static let name = "launchIntroDock"
}

/// The real header wordmark's on-screen frame, published from `RoamRootView`
/// — which sits behind the intro for its entire run, just invisible — so the
/// intro's docked wordmark can land in its exact usual spot.
struct HeaderWordmarkFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        guard next != .zero else { return }
        value = next
    }
}

/// Roam's launch sequence.
///
/// A road draws itself across the canvas with a lit head running along it,
/// waypoints igniting as that head passes them. The headlight then sweeps off
/// the end of the road and across the wordmark — the same light that drove the
/// route is what switches the brand on. Everything is painted from the active
/// theme, so the intro is a different piece of art on each of the six schemes.
struct LaunchIntroView: View {
    @ObservedObject private var theme = ThemeManager.shared
    let onFinish: () -> Void
    /// The real header wordmark's live on-screen frame, read by `RoamApp`
    /// from `RoamRootView` (which sits behind the intro the whole time) and
    /// handed down here so the docked mark lands exactly where the header's
    /// own wordmark already sits, rather than an inset kept in sync by hand.
    let dockTargetFrame: CGRect

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var traceProgress: Double = 0
    @State private var sweepProgress: Double = 0
    @State private var isLockupVisible = false
    @State private var hasHandedOff = false
    @State private var isGlobeIntroActive = false
    @State private var isGlobeWordmarkVisible = false
    @State private var isWordmarkDocked = false
    @State private var wordmarkWidth: CGFloat = 0
    @State private var wordmarkSliceProgress: Double = 0

    private var choreography: LaunchIntroChoreography.Type { LaunchIntroChoreography.self }

    /// Reduce Motion falls back to the original road-trace/wordmark sequence
    /// with no globe animation involved.
    private var usesGlobeIntro: Bool { !reduceMotion }

    var body: some View {
        ZStack {
            AppDesign.canvas.ignoresSafeArea()

            if usesGlobeIntro {
                if isGlobeIntroActive {
                    AsciiGlobeIntroLayer(themeID: theme.currentID, onFinished: handOffFromGlobeIntro)
                }
                globeWordmarkOverlay
            } else {
                atmosphere

                GeometryReader { geometry in
                    let sceneWidth = min(geometry.size.width - 48, 340)
                    let scale = sceneWidth / choreography.canvasWidth

                    VStack(spacing: 26) {
                        Spacer(minLength: 0)

                        RoadTrace(
                            traceProgress: traceProgress,
                            showsHead: !reduceMotion && traceProgress > 0 && traceProgress < 1
                        )
                        .frame(width: choreography.canvasWidth, height: choreography.canvasHeight)
                        .scaleEffect(scale)
                        .frame(width: sceneWidth, height: choreography.canvasHeight * scale)

                        lockup

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        // Nobody should be held hostage by a brand moment. A tap finishes it.
        .contentShape(Rectangle())
        .onTapGesture(perform: handOff)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Roam")
        .accessibilityAddTraits(.isImage)
        .onPreferenceChange(WordmarkWidthKey.self) { width in
            guard wordmarkWidth == 0, width > 0 else { return }
            wordmarkWidth = width
        }
        .onAppear(perform: start)
        .onChange(of: isLockupVisible) { _, visible in
            guard visible, !reduceMotion else { return }
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)
        }
        .onChange(of: isGlobeWordmarkVisible) { _, visible in
            guard visible else { return }
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)
        }
    }

    // MARK: - Layers

    /// The wordmark arrives large and centered above the still-turning globe,
    /// holds for a beat, then glides down to the top-left corner it occupies
    /// everywhere else in the app — so the intro hands the brand over to the
    /// header instead of cutting to it. The globe's own fade to canvas color
    /// dims it out from underneath as the mark lands.
    private var globeWordmarkOverlay: some View {
        GeometryReader { geometry in
            let origin = choreography.wordmarkOrigin(
                docked: isWordmarkDocked,
                screenWidth: Double(geometry.size.width),
                screenHeight: Double(geometry.size.height),
                wordmarkWidth: Double(wordmarkWidth),
                measuredDockedTarget: dockTargetFrame == .zero
                    ? nil
                    : IntroPoint(x: dockTargetFrame.origin.x, y: dockTargetFrame.origin.y)
            )

            introWordmark
                .scaleEffect(
                    isWordmarkDocked ? choreography.wordmarkDockedScale : 1,
                    anchor: .topLeading
                )
                .offset(x: CGFloat(origin.x), y: CGFloat(origin.y))
                .opacity(isGlobeWordmarkVisible ? 1 : 0)
        }
        .allowsHitTesting(false)
    }

    /// Drawn once at hero size and rasterized, so the dock is a single GPU
    /// transform on a finished image. Scaling `Text` itself re-lays out and
    /// re-renders the glyphs on every frame, which is what makes the move
    /// stutter; it also means the mark that lands in the corner was rendered
    /// large and shrunk, never blown up.
    private var introWordmark: some View {
        RoamWordmark(
            fontSize: choreography.wordmarkHeroFontSize,
            foreground: theme.palette.inkPrimary.color.opacity(0.92),
            sliceProgress: wordmarkSliceProgress,
            reduceMotion: reduceMotion
        )
            .fixedSize()
            .background(wordmarkWidthReader)
    }

    /// The hero mark is centered by arithmetic rather than by layout, because
    /// it has to end up left-aligned; that needs the mark's own width. Read
    /// once — a width change arriving mid-glide would re-target the animation.
    private var wordmarkWidthReader: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: WordmarkWidthKey.self, value: proxy.size.width)
        }
    }

    /// Two soft pools of theme light behind the road. They give the canvas
    /// depth without becoming a recognizable shape that competes with the
    /// wordmark.
    private var atmosphere: some View {
        MapGridTexture()
        .opacity(isLockupVisible ? 1 : 0.35)
        .scaleEffect(isLockupVisible ? 1 : 0.9)
        .animation(reduceMotion ? .easeOut(duration: 0.3) : AppAnimation.reveal, value: isLockupVisible)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var lockup: some View {
        VStack(spacing: AppDesign.space12) {
            SweptWordmark(sweepProgress: sweepProgress, reduceMotion: reduceMotion)

            Text("Know the road before you drive it.")
                .font(.footnote.weight(.medium))
                .foregroundStyle(AppDesign.Ink.secondary)
                .multilineTextAlignment(.center)
                .opacity(isLockupVisible ? 1 : 0)
                .offset(y: isLockupVisible || reduceMotion ? 0 : 8)
                .animation(
                    reduceMotion
                        ? .easeOut(duration: choreography.reducedFadeDuration)
                        : AppAnimation.hero.delay(choreography.revealDelay + 0.24),
                    value: isLockupVisible
                )
        }
    }

    // MARK: - Sequence

    /// Reduce Motion skips straight to the native trace/wordmark beat.
    /// Everyone else gets the ASCII globe, with the wordmark fading in on
    /// top of it partway through.
    private func start() {
        guard usesGlobeIntro else {
            play()
            return
        }
        isGlobeIntroActive = true
        DispatchQueue.main.asyncAfter(deadline: .now() + choreography.videoWordmarkDelay) {
            withAnimation(.easeOut(duration: choreography.videoWordmarkFadeDuration)) {
                isGlobeWordmarkVisible = true
            }
            withAnimation(AppAnimation.wordmarkResolve) {
                wordmarkSliceProgress = 1
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + choreography.wordmarkDockDelay) {
            // One animation drives both scale and offset, so the mark reads
            // as a single object moving rather than a size change racing a
            // position change.
            withAnimation(
                .timingCurve(0.32, 0, 0.16, 1, duration: choreography.wordmarkDockDuration)
            ) {
                isWordmarkDocked = true
            }
        }
    }

    /// The wordmark is already lit and the globe has already faded itself to
    /// canvas color, so there's nothing left to transition to — just hold on
    /// the mark for a beat, then hand off.
    private func handOffFromGlobeIntro() {
        isGlobeIntroActive = false
        scheduleHandOff(after: choreography.videoWordmarkHoldDuration)
    }

    private func play() {
        guard !reduceMotion else {
            withAnimation(.easeOut(duration: choreography.reducedFadeDuration)) {
                traceProgress = 1
                sweepProgress = 1
                isLockupVisible = true
            }
            scheduleHandOff(after: choreography.reducedTotalDuration)
            return
        }

        withAnimation(.timingCurve(0.32, 0, 0.16, 1, duration: choreography.traceDuration)) {
            traceProgress = 1
        }
        withAnimation(
            .timingCurve(0.4, 0, 0.2, 1, duration: choreography.revealDuration)
                .delay(choreography.revealDelay)
        ) {
            sweepProgress = 1
        }
        withAnimation(AppAnimation.reveal.delay(choreography.revealDelay)) {
            isLockupVisible = true
        }
        scheduleHandOff(after: choreography.totalDuration)
    }

    private func scheduleHandOff(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: handOff)
    }

    /// Idempotent: tap-to-skip and the scheduled finish can both arrive.
    private func handOff() {
        guard !hasHandedOff else { return }
        hasHandedOff = true
        onFinish()
    }
}

/// Measured width of the unscaled wordmark, used to center its hero pose.
private struct WordmarkWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Atmosphere texture

/// A faint dotted grid, the same language as the map screens the intro hands
/// off to. It ties the brand moment to what the app actually is instead of
/// leaving the canvas as empty color.
private struct MapGridTexture: View {
    @ObservedObject private var theme = ThemeManager.shared
    private let spacing: CGFloat = 28

    var body: some View {
        Canvas { context, size in
            let dot = Path(ellipseIn: CGRect(x: 0, y: 0, width: 1.6, height: 1.6))
            var x: CGFloat = spacing / 2
            while x < size.width {
                var y: CGFloat = spacing / 2
                while y < size.height {
                    context.opacity = 0.5
                    context.translateBy(x: x, y: y)
                    context.fill(dot, with: .color(AppDesign.cardStroke))
                    context.translateBy(x: -x, y: -y)
                    y += spacing
                }
                x += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Road

private struct RoadTrace: View {
    @ObservedObject private var theme = ThemeManager.shared
    let traceProgress: Double
    let showsHead: Bool

    var body: some View {
        ZStack {
            // The unlit road, so the trace reads as light filling a route that
            // was already there rather than a line being invented.
            roadPath
                .stroke(
                    AppDesign.cardStroke,
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )

            roadPath
                .trim(from: 0, to: traceProgress)
                .stroke(
                    AppDesign.accent,
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .shadow(color: AppDesign.accent.opacity(0.45), radius: 12)

            // Comet trail: a brighter, blurred segment just behind the head.
            roadPath
                .trim(from: LaunchIntroChoreography.trailStart(for: traceProgress), to: traceProgress)
                .stroke(
                    AppDesign.safety.opacity(showsHead ? 0.9 : 0),
                    style: StrokeStyle(lineWidth: 12, lineCap: .round)
                )
                .blur(radius: 7)

            milestones
            head
        }
        .drawingGroup()
    }

    private var roadPath: Path {
        Path { path in
            path.move(to: cgPoint(LaunchIntroChoreography.start))
            path.addCurve(
                to: cgPoint(LaunchIntroChoreography.end),
                control1: cgPoint(LaunchIntroChoreography.control1),
                control2: cgPoint(LaunchIntroChoreography.control2)
            )
        }
    }

    private var milestones: some View {
        ForEach(Array(LaunchIntroChoreography.milestones.enumerated()), id: \.offset) { _, fraction in
            MilestoneMarker(
                center: cgPoint(LaunchIntroChoreography.point(at: fraction)),
                isLit: LaunchIntroChoreography.isMilestoneLit(fraction, traceProgress: traceProgress)
            )
        }
    }

    /// The travelling light. Elongated along the direction of travel so it
    /// reads as a vehicle's beam rather than a bouncing ball, with a soft
    /// halo behind it for depth against the flat road.
    private var head: some View {
        let position = cgPoint(LaunchIntroChoreography.point(at: traceProgress))
        let heading = LaunchIntroChoreography.headingDegrees(at: traceProgress)

        return ZStack {
            Circle()
                .fill(AppDesign.safety.opacity(0.35))
                .frame(width: 34, height: 34)
                .blur(radius: 10)
                .position(position)

            Capsule()
                .fill(AppDesign.Ink.primary)
                .frame(width: 22, height: 10)
                .rotationEffect(.degrees(heading))
                .shadow(color: AppDesign.safety.opacity(0.8), radius: 10)
                .position(position)
        }
        .opacity(showsHead ? 1 : 0)
    }

    private func cgPoint(_ point: IntroPoint) -> CGPoint {
        CGPoint(x: point.x, y: point.y)
    }
}

/// A single waypoint dot plus its one-shot ignition pulse — an expanding,
/// fading ring fired the moment the trace passes it, so a waypoint reads as
/// *reached* rather than merely recolored.
private struct MilestoneMarker: View {
    let center: CGPoint
    let isLit: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasPulsed = false
    @State private var pulseActive = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(AppDesign.safety, lineWidth: 2)
                .frame(width: 13, height: 13)
                .scaleEffect(pulseActive ? 2.4 : 1)
                .opacity(pulseActive ? 0 : 0.8)
                .position(center)

            Circle()
                .fill(AppDesign.canvas)
                .frame(width: 13, height: 13)
                .overlay {
                    Circle()
                        .stroke(isLit ? AppDesign.safety : AppDesign.cardStrokeStrong, lineWidth: 3)
                }
                .scaleEffect(isLit ? 1 : 0.55)
                .shadow(color: AppDesign.safety.opacity(isLit ? 0.6 : 0), radius: 8)
                .position(center)
                .animation(AppAnimation.selection, value: isLit)
        }
        .onChange(of: isLit) { _, lit in
            guard lit, !hasPulsed, !reduceMotion else { return }
            hasPulsed = true
            withAnimation(.easeOut(duration: 0.45)) {
                pulseActive = true
            }
        }
    }
}

// MARK: - Wordmark

/// The wordmark sits dim until a band of theme light crosses it. Behind the
/// band it stays lit, so the sweep switches the brand on rather than merely
/// passing over it.
private struct SweptWordmark: View {
    @ObservedObject private var theme = ThemeManager.shared
    let sweepProgress: Double
    let reduceMotion: Bool

    var body: some View {
        BrandWordmark()
            .opacity(0.16 + (0.84 * sweepProgress))
        .scaleEffect(reduceMotion ? 1 : 0.98 + 0.02 * sweepProgress)
    }
}

#Preview {
    LaunchIntroView(onFinish: {}, dockTargetFrame: .zero)
        .environmentObject(ThemeManager.shared)
}
