import SwiftUI

struct HowRoamWorksSheet: View {
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    private let factors = RouteFactorExplanation.all

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CGFloat(HowRoamWorksLayoutSpec.sectionSpacing)) {
                    introduction
                    processSection
                    factorsSection
                    evidenceSection
                    recordedDriveSection
                    scoreSection
                    privacySection
                    limitsSection
                }
                .padding(.horizontal, AppDesign.contentPadding)
                .padding(.top, CGFloat(HowRoamWorksLayoutSpec.topPadding))
                .padding(.bottom, CGFloat(HowRoamWorksLayoutSpec.bottomPadding))
                .frame(maxWidth: CGFloat(HowRoamWorksLayoutSpec.maximumContentWidth))
                .frame(maxWidth: .infinity)
            }
            .background(AppCanvasBackground())
            .navigationTitle("How Roam works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: AppDesign.space12) {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(AppDesign.accent)
                .frame(width: 52, height: 52)
                .background(AppDesign.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 15, style: .continuous))

            Text("A clearer picture of the drive")
                .font(.title2.weight(.bold))
                .tracking(-0.4)
                .foregroundStyle(AppDesign.Ink.primary)

            Text("Roam evaluates the route and departure time, then explains which parts may require more attention. It does not decide whether someone is safe or legally allowed to drive.")
                .font(.subheadline)
                .foregroundStyle(AppDesign.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, AppDesign.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var processSection: some View {
        HowItWorksSection(title: "From route to result") {
            VStack(spacing: 0) {
                ProcessStepRow(
                    number: 1,
                    title: "Build the route",
                    detail: "Routing data supplies the route shape, distance, expected duration, maneuvers, and available alternatives."
                )
                Divider().padding(.leading, 52)
                ProcessStepRow(
                    number: 2,
                    title: "Add route context",
                    detail: "Roam checks the selected departure time against traffic, daylight, weather, road details, and mapped turn controls when those sources are available."
                )
                Divider().padding(.leading, 52)
                ProcessStepRow(
                    number: 3,
                    title: "Explain the demand",
                    detail: "The result shows an overall difficulty score, the strongest contributing factors, route hotspots, and calmer alternatives when available."
                )
            }
            .premiumCard()
        }
    }

    private var factorsSection: some View {
        HowItWorksSection(title: "What the route score considers") {
            VStack(spacing: 0) {
                ForEach(Array(factors.enumerated()), id: \.element.id) { index, factor in
                    RouteFactorRow(factor: factor)
                    if index < factors.count - 1 {
                        Divider().padding(.leading, 52)
                    }
                }
            }
            .premiumCard()
        }
    }

    private var evidenceSection: some View {
        HowItWorksSection(title: "How confidence is shown") {
            VStack(alignment: .leading, spacing: 0) {
                EvidenceLevelRow(
                    title: "Well supported",
                    detail: "The important route inputs were available and agree strongly enough to support the explanation.",
                    symbol: "checkmark.seal.fill",
                    color: AppDesign.positive
                )
                Divider()
                EvidenceLevelRow(
                    title: "Partial evidence",
                    detail: "Some live or mapped inputs were unavailable. Roam still shows the result and identifies the missing coverage.",
                    symbol: "circle.lefthalf.filled",
                    color: AppDesign.safety
                )
                Divider()
                EvidenceLevelRow(
                    title: "Limited evidence",
                    detail: "The score relies on a smaller set of route facts. Treat the explanation as an early estimate.",
                    symbol: "exclamationmark.circle.fill",
                    color: AppDesign.Ink.secondary
                )
            }
            .premiumCard()
        }
    }

    private var scoreSection: some View {
        HowItWorksSection(title: "What the score means") {
            VStack(alignment: .leading, spacing: AppDesign.space12) {
                ScoreMeaningRow(range: "0 to 1.9", label: "Very easy", color: AppDesign.positive)
                ScoreMeaningRow(range: "2 to 3.9", label: "Easy", color: AppDesign.positive)
                ScoreMeaningRow(range: "4 to 5.9", label: "Moderate", color: AppDesign.safety)
                ScoreMeaningRow(range: "6 to 7.9", label: "Hard", color: AppDesign.safety)
                ScoreMeaningRow(range: "8 to 10", label: "Very hard", color: AppDesign.danger)

                Divider()

                Text("Scores compare route demand, not driver quality. A higher number means the route contains more demanding conditions or a greater concentration of them.")
                    .font(.footnote)
                    .foregroundStyle(AppDesign.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .premiumCard()
        }
    }

    private var recordedDriveSection: some View {
        HowItWorksSection(title: "What a recorded drive measures") {
            VStack(spacing: 0) {
                RecordedSignalRow(
                    title: "Route trace",
                    detail: "GPS continuity, distance, speed, duration, and overlap with a planned practice route.",
                    symbol: "location.fill"
                )
                Divider().padding(.leading, 52)
                RecordedSignalRow(
                    title: "Speed changes",
                    detail: "Measured changes in speed can identify rapid acceleration and hard braking events.",
                    symbol: "speedometer"
                )
                Divider().padding(.leading, 52)
                RecordedSignalRow(
                    title: "Turning motion",
                    detail: "Motion and course changes can identify sharper cornering when sensor quality is sufficient.",
                    symbol: "arrow.turn.up.right"
                )
                Divider().padding(.leading, 52)
                RecordedSignalRow(
                    title: "Experience coverage",
                    detail: "Qualifying miles can contribute to after-dark, faster-road, continuous-driving, and weekly progress totals.",
                    symbol: "chart.line.uptrend.xyaxis"
                )
            }
            .premiumCard()
        }
    }

    private var privacySection: some View {
        HowItWorksSection(title: "Your recorded drives") {
            HStack(alignment: .top, spacing: AppDesign.space12) {
                Image(systemName: "lock.shield.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppDesign.accent)
                    .frame(width: 40, height: 40)
                    .background(AppDesign.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: AppDesign.space8) {
                    Text("Readiness uses local evidence")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppDesign.Ink.primary)
                    Text("When recorded drives are available, Roam compares measured experience with the route's demands. GPS overlap, continuous driving, after-dark miles, faster-road miles, and measured behavior can contribute to that comparison.")
                        .font(.footnote)
                        .foregroundStyle(AppDesign.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Profile details such as your name and licensing stage never change a route score or driving score.")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppDesign.Ink.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .premiumCard()
        }
    }

    private var limitsSection: some View {
        HowItWorksSection(title: "Important limits") {
            VStack(alignment: .leading, spacing: AppDesign.space12) {
                LimitRow(text: "Roam is a planning and coaching tool, not a safety guarantee.")
                LimitRow(text: "Conditions can change after analysis. Check the road and weather before leaving.")
                LimitRow(text: "Map and live-data coverage varies by location and departure time.")
                LimitRow(text: "Follow local laws, license restrictions, supervision rules, and your own judgment.")
                LimitRow(text: "If a route feels beyond your experience, choose an alternative or travel with a qualified supervising driver.")
            }
            .premiumCard()
        }
    }
}

private struct HowItWorksSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: CGFloat(HowRoamWorksLayoutSpec.titleContentSpacing)) {
            Text(title)
                .font(AppDesign.Typography.sectionTitle)
                .foregroundStyle(AppDesign.Ink.primary)
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

private struct RecordedSignalRow: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: AppDesign.space12) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppDesign.Ink.secondary)
                .frame(width: 36, height: 36)
                .background(AppDesign.trackSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppDesign.Ink.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(AppDesign.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, CGFloat(HowRoamWorksLayoutSpec.rowVerticalPadding))
        .accessibilityElement(children: .combine)
    }
}

private struct ProcessStepRow: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: AppDesign.space12) {
            Text("\(number)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(AppDesign.accentForeground)
                .frame(width: 32, height: 32)
                .background(AppDesign.accent, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppDesign.Ink.primary)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(AppDesign.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, CGFloat(HowRoamWorksLayoutSpec.rowVerticalPadding))
        .accessibilityElement(children: .combine)
    }
}

private struct RouteFactorExplanation: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String

    static let all: [RouteFactorExplanation] = [
        .init(id: "traffic", title: "Traffic", detail: "Expected congestion and delay around the selected departure time.", symbol: "car.2.fill"),
        .init(id: "fast-roads", title: "Fast roads", detail: "Distance and time spent on roads with higher posted speeds.", symbol: "speedometer"),
        .init(id: "merges", title: "Merges", detail: "Highway entries, exits, and lane changes identified along the route.", symbol: "arrow.triangle.merge"),
        .init(id: "intersections", title: "Complex intersections", detail: "Dense maneuvers, difficult junctions, and closely spaced decisions.", symbol: "arrow.triangle.branch"),
        .init(id: "weather", title: "Weather and visibility", detail: "Forecast precipitation, wind, visibility, and other conditions along the trip.", symbol: "cloud.sun.rain.fill"),
        .init(id: "dark", title: "After-dark driving", detail: "The share of the trip expected to occur outside daylight hours.", symbol: "moon.stars.fill"),
        .init(id: "duration", title: "Sustained drive", detail: "Total drive time and how long attention must be maintained continuously.", symbol: "clock.fill"),
        .init(id: "road", title: "Road conditions", detail: "Road class, mapped construction, turn controls, and available roadway metadata.", symbol: "road.lanes")
    ]
}

private struct RouteFactorRow: View {
    let factor: RouteFactorExplanation

    var body: some View {
        HStack(alignment: .top, spacing: AppDesign.space12) {
            Image(systemName: factor.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppDesign.accent)
                .frame(width: 36, height: 36)
                .background(AppDesign.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(factor.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppDesign.Ink.primary)
                Text(factor.detail)
                    .font(.caption)
                    .foregroundStyle(AppDesign.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, CGFloat(HowRoamWorksLayoutSpec.rowVerticalPadding))
        .accessibilityElement(children: .combine)
    }
}

private struct EvidenceLevelRow: View {
    let title: String
    let detail: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: AppDesign.space12) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(AppDesign.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, CGFloat(HowRoamWorksLayoutSpec.rowVerticalPadding))
        .accessibilityElement(children: .combine)
    }
}

private struct ScoreMeaningRow: View {
    let range: String
    let label: String
    let color: Color

    var body: some View {
        HStack {
            Text(range)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(AppDesign.Ink.primary)
            Spacer()
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(color.opacity(0.12), in: Capsule())
        }
        .accessibilityElement(children: .combine)
    }
}

private struct LimitRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: AppDesign.space8) {
            Image(systemName: "checkmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppDesign.Ink.secondary)
                .frame(width: 18, height: 18)
            Text(text)
                .font(.footnote)
                .foregroundStyle(AppDesign.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    HowRoamWorksSheet()
}
