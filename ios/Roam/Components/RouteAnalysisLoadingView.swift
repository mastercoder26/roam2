import SwiftUI

/// A short visual explanation of what Roam is doing: trace a route, assemble
/// its signal points into a car, then send that car on its way to the results.
struct RouteAnalysisLoadingView: View {
    @ObservedObject private var theme = ThemeManager.shared
    let isFinishing: Bool
    let onDepartureComplete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var routeProgress: CGFloat = 0
    @State private var dotsAreFormed = false
    @State private var departureRequested = false
    @State private var isDrivingAway = false

    var body: some View {
        ZStack {
            AppDesign.canvas.ignoresSafeArea()

            GeometryReader { geometry in
                let horizontalPadding: CGFloat = 28
                let sceneWidth = LayoutResponsiveness.loadingSceneWidth(
                    availableWidth: geometry.size.width,
                    horizontalPadding: horizontalPadding
                )
                let sceneScale = sceneWidth / 320

                VStack(spacing: 28) {
                    DotCarIllustration(
                        routeProgress: routeProgress,
                        dotsAreFormed: dotsAreFormed,
                        isDrivingAway: isDrivingAway,
                        reduceMotion: reduceMotion
                    )
                    .scaleEffect(sceneScale)
                    .frame(width: sceneWidth, height: sceneWidth * (190 / 320))
                    .clipped()

                    // The status title already narrates each step in turn, so it
                    // carries the explanation on its own rather than repeating
                    // it in a static caption underneath.
                    Text(statusTitle)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(AppDesign.Ink.primary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: min(290, sceneWidth))

                    ProgressView()
                        .tint(AppDesign.accent)
                }
                .padding(horizontalPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Analyzing route difficulty")
        .onAppear(perform: startSequence)
        .onChange(of: isFinishing) { _, finishing in
            guard finishing else { return }
            requestDeparture()
        }
    }

    private var statusTitle: String {
        if isDrivingAway { return "Your route is ready" }
        if dotsAreFormed { return "Reading the road ahead" }
        return "Tracing your route"
    }

    private func startSequence() {
        guard !reduceMotion else {
            routeProgress = 1
            dotsAreFormed = true
            return
        }

        withAnimation(AppAnimation.routeTrace) {
            routeProgress = 1
        }

        // Let the route finish drawing before the data points assemble into a
        // car. The story reads in a single direction: trace, understand, go.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.68) {
            withAnimation(AppAnimation.content) {
                dotsAreFormed = true
            }
            if departureRequested {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: driveAway)
            }
        }
    }

    private func requestDeparture() {
        guard !isDrivingAway else { return }
        guard dotsAreFormed else {
            departureRequested = true
            return
        }
        driveAway()
    }

    private func driveAway() {
        guard !isDrivingAway else { return }
        guard !reduceMotion else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: onDepartureComplete)
            return
        }

        withAnimation(AppAnimation.departure) {
            isDrivingAway = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34, execute: onDepartureComplete)
    }
}

private struct DotCarIllustration: View {
    @ObservedObject private var theme = ThemeManager.shared
    let routeProgress: CGFloat
    let dotsAreFormed: Bool
    let isDrivingAway: Bool
    let reduceMotion: Bool

    private let canvasSize = CGSize(width: 320, height: 190)

    var body: some View {
        ZStack {
            routeLine
            // A single display-synced timeline drives the whole illustration.
            // Individual timelines per dot create unnecessary work during a
            // network wait and make this otherwise small loading scene costly.
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                dotCar(time: context.date.timeIntervalSinceReferenceDate)
                    .offset(x: isDrivingAway ? -390 : 0)
                    .opacity(isDrivingAway ? 0.85 : 1)
                    .animation(reduceMotion ? AppAnimation.departureReduced : AppAnimation.departure, value: isDrivingAway)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .clipped()
    }

    private var routeLine: some View {
        Path { path in
            path.move(to: CGPoint(x: 12, y: 145))
            path.addCurve(
                to: CGPoint(x: 308, y: 145),
                control1: CGPoint(x: 82, y: 128),
                control2: CGPoint(x: 212, y: 164)
            )
        }
        .trim(from: 0, to: routeProgress)
        .stroke(
            AppDesign.safety,
            style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round)
        )
        .shadow(color: AppDesign.safety.opacity(0.35), radius: 12)
    }

    private func dotCar(time: TimeInterval) -> some View {
        ZStack {
            ForEach(CarDots.all) { dot in
                FloatingDot(
                    size: dot.size,
                    color: dot.color,
                    phase: dot.phase,
                    time: time,
                    isVisible: dotsAreFormed,
                    isBobbing: dotsAreFormed && !isDrivingAway && !reduceMotion
                )
                .position(
                    x: dotsAreFormed ? dot.x : dot.x * 0.92 + 12,
                    y: dotsAreFormed ? dot.y : 145
                )
                .animation(
                    AppAnimation.content
                        .delay(dot.phase * 0.028),
                    value: dotsAreFormed
                )
            }

            DotWheel(
                center: CGPoint(x: 92, y: 126),
                phase: 0,
                time: time,
                isVisible: dotsAreFormed,
                isBobbing: dotsAreFormed && !isDrivingAway && !reduceMotion,
                isSpinning: isDrivingAway
            )
            DotWheel(
                center: CGPoint(x: 231, y: 126),
                phase: 8,
                time: time,
                isVisible: dotsAreFormed,
                isBobbing: dotsAreFormed && !isDrivingAway && !reduceMotion,
                isSpinning: isDrivingAway
            )
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }
}

private struct FloatingDot: View {
    let size: CGFloat
    let color: Color
    let phase: Double
    let time: TimeInterval
    let isVisible: Bool
    let isBobbing: Bool

    var body: some View {
        let bob = isBobbing ? sin(time * 2.2 + phase) * 2.2 : 0

        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .offset(y: bob)
            .opacity(isVisible ? 1 : 0)
            .scaleEffect(isVisible ? 1 : 0.72)
            .animation(
                AppAnimation.selection
                    .delay(phase * 0.024),
                value: isVisible
            )
    }
}

private struct DotWheel: View {
    @ObservedObject private var theme = ThemeManager.shared
    let center: CGPoint
    let phase: Double
    let time: TimeInterval
    let isVisible: Bool
    let isBobbing: Bool
    let isSpinning: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(AppDesign.cardStrokeStrong, lineWidth: 2)
                .frame(width: 34, height: 34)

            ForEach(0..<8, id: \.self) { index in
                let angle = Double(index) * .pi / 4
                FloatingDot(
                    size: index.isMultiple(of: 2) ? 8 : 6,
                    color: index.isMultiple(of: 2) ? AppDesign.safety : AppDesign.Ink.primary.opacity(0.88),
                    phase: phase + Double(index),
                    time: time,
                    isVisible: isVisible,
                    isBobbing: isBobbing
                )
                .offset(
                    x: CGFloat(cos(angle) * 16),
                    y: CGFloat(sin(angle) * 16)
                )
            }

            FloatingDot(
                size: 7,
                color: AppDesign.Ink.primary,
                phase: phase + 9,
                time: time,
                isVisible: isVisible,
                isBobbing: isBobbing
            )
        }
        .frame(width: 42, height: 42)
        .rotationEffect(.degrees(isSpinning && !reduceMotion ? -720 : 0))
        .animation(reduceMotion ? AppAnimation.departureReduced : AppAnimation.departure, value: isSpinning)
        .position(x: isVisible ? center.x : center.x * 0.92 + 12, y: isVisible ? center.y : 145)
        .animation(
            AppAnimation.content.delay(phase * 0.028),
            value: isVisible
        )
    }
}

private struct CarDot: Identifiable {
    let id: Int
    let x: CGFloat
    let y: CGFloat
    let size: CGFloat
    let phase: Double
    let isAccent: Bool
    let detail: CarDetail

    init(
        id: Int,
        x: CGFloat,
        y: CGFloat,
        size: CGFloat,
        phase: Double,
        isAccent: Bool,
        detail: CarDetail = .body
    ) {
        self.id = id
        self.x = x
        self.y = y
        self.size = size
        self.phase = phase
        self.isAccent = isAccent
        self.detail = detail
    }

    var color: Color {
        switch detail {
        case .body:
            return isAccent ? AppDesign.safety : AppDesign.Ink.primary
        case .glass:
            return AppDesign.accent
        case .trim:
            return AppDesign.Ink.secondary
        case .headlamp:
            return AppDesign.safety.opacity(0.85)
        case .tailLamp:
            return AppDesign.danger
        }
    }
}

private enum CarDetail {
    case body
    case glass
    case trim
    case headlamp
    case tailLamp
}

private enum CarDots {
    static var all: [CarDot] { shell + windows + details }

    static let shell: [CarDot] = [
        .init(id: 0, x: 44, y: 116, size: 8, phase: 0, isAccent: true),
        .init(id: 1, x: 58, y: 106, size: 7, phase: 1, isAccent: false),
        .init(id: 2, x: 73, y: 99, size: 8, phase: 2, isAccent: false),
        .init(id: 3, x: 91, y: 96, size: 7, phase: 3, isAccent: true),
        .init(id: 4, x: 108, y: 91, size: 8, phase: 4, isAccent: false),
        .init(id: 5, x: 119, y: 76, size: 7, phase: 5, isAccent: true),
        .init(id: 6, x: 133, y: 65, size: 8, phase: 6, isAccent: false),
        .init(id: 7, x: 151, y: 58, size: 7, phase: 7, isAccent: false),
        .init(id: 8, x: 172, y: 57, size: 8, phase: 8, isAccent: true),
        .init(id: 9, x: 192, y: 64, size: 7, phase: 9, isAccent: false),
        .init(id: 10, x: 207, y: 77, size: 8, phase: 10, isAccent: false),
        .init(id: 11, x: 221, y: 91, size: 7, phase: 11, isAccent: true),
        .init(id: 12, x: 244, y: 96, size: 8, phase: 12, isAccent: false),
        .init(id: 13, x: 263, y: 104, size: 7, phase: 13, isAccent: false),
        .init(id: 14, x: 277, y: 115, size: 8, phase: 14, isAccent: true),
        .init(id: 15, x: 271, y: 126, size: 7, phase: 15, isAccent: false),
        .init(id: 16, x: 250, y: 132, size: 8, phase: 16, isAccent: false),
        .init(id: 17, x: 210, y: 134, size: 7, phase: 17, isAccent: true),
        .init(id: 18, x: 185, y: 134, size: 8, phase: 18, isAccent: false),
        .init(id: 19, x: 157, y: 134, size: 7, phase: 19, isAccent: false),
        .init(id: 20, x: 130, y: 134, size: 8, phase: 20, isAccent: true),
        .init(id: 21, x: 70, y: 132, size: 7, phase: 21, isAccent: false),
        .init(id: 22, x: 49, y: 127, size: 8, phase: 22, isAccent: false)
    ]

    // A cool blue cluster makes the cabin read as separate glass rather than
    // simply a raised part of the body.
    static let windows: [CarDot] = [
        .init(id: 23, x: 123, y: 85, size: 6, phase: 23, isAccent: false, detail: .glass),
        .init(id: 24, x: 131, y: 76, size: 6, phase: 24, isAccent: false, detail: .glass),
        .init(id: 25, x: 142, y: 69, size: 7, phase: 25, isAccent: false, detail: .glass),
        .init(id: 26, x: 156, y: 66, size: 7, phase: 26, isAccent: false, detail: .glass),
        .init(id: 27, x: 172, y: 66, size: 7, phase: 27, isAccent: false, detail: .glass),
        .init(id: 28, x: 187, y: 70, size: 6, phase: 28, isAccent: false, detail: .glass),
        .init(id: 29, x: 198, y: 78, size: 7, phase: 29, isAccent: false, detail: .glass),
        .init(id: 30, x: 205, y: 86, size: 6, phase: 30, isAccent: false, detail: .glass)
    ]

    static let details: [CarDot] = [
        // Windshield / rear-window pillars and the door seam.
        .init(id: 31, x: 113, y: 88, size: 4, phase: 31, isAccent: false, detail: .trim),
        .init(id: 32, x: 202, y: 91, size: 4, phase: 32, isAccent: false, detail: .trim),
        .init(id: 33, x: 163, y: 86, size: 3, phase: 33, isAccent: false, detail: .trim),
        .init(id: 34, x: 163, y: 99, size: 3, phase: 34, isAccent: false, detail: .trim),
        .init(id: 35, x: 163, y: 112, size: 3, phase: 35, isAccent: false, detail: .trim),
        // Door handle, bumpers, headlights, and taillight.
        .init(id: 36, x: 177, y: 103, size: 4, phase: 36, isAccent: false, detail: .trim),
        .init(id: 37, x: 41, y: 121, size: 5, phase: 37, isAccent: false, detail: .trim),
        .init(id: 38, x: 281, y: 121, size: 5, phase: 38, isAccent: false, detail: .trim),
        .init(id: 39, x: 43, y: 108, size: 6, phase: 39, isAccent: false, detail: .headlamp),
        .init(id: 40, x: 278, y: 108, size: 6, phase: 40, isAccent: false, detail: .tailLamp),
        .init(id: 41, x: 138, y: 120, size: 3, phase: 41, isAccent: false, detail: .trim),
        .init(id: 42, x: 185, y: 120, size: 3, phase: 42, isAccent: false, detail: .trim)
    ]
}

#Preview {
    RouteAnalysisLoadingView(isFinishing: false, onDepartureComplete: {})
}
