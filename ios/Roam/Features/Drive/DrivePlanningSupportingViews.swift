import SwiftUI

/// Break timing and practice debrief UI are kept out of the recording surface
/// so drive capture state is not coupled to follow-up coaching presentation.
struct BreakRecommendationsView: View {
    @ObservedObject private var theme = ThemeManager.shared
    let route: ScoredRoute
    let continuousMinutes: Double

    private var recommendation: BreakRecommendation {
        BreakRecommendation(route: route, continuousMinutes: continuousMinutes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.space12) {
            HStack(alignment: .top, spacing: AppDesign.space12) {
                IconTile(symbol: recommendation.symbol, color: recommendation.color)
                VStack(alignment: .leading, spacing: 3) {
                    Text(recommendation.title)
                        .font(.subheadline.weight(.semibold))
                    Text(recommendation.detail)
                        .font(.footnote)
                        .foregroundStyle(AppDesign.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !recommendation.stops.isEmpty {
                VStack(alignment: .leading, spacing: AppDesign.space8) {
                    ForEach(recommendation.stops) { stop in
                        HStack(spacing: 10) {
                            Text(stop.label)
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(recommendation.color)
                                .frame(width: 54, alignment: .leading)
                            Capsule(style: .continuous)
                                .fill(recommendation.color.opacity(0.18))
                                .frame(width: 3, height: 22)
                            Text(stop.reason)
                                .font(.caption)
                                .foregroundStyle(AppDesign.Ink.secondary)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(12)
                .background(
                    AppDesign.cardSurface,
                    in: RoundedRectangle(cornerRadius: AppDesign.cornerRadiusSmall, style: .continuous)
                )
            }
        }
    }
}

private struct BreakRecommendation {
    struct Stop: Identifiable {
        let id = UUID()
        let minute: Int
        let reason: String

        var label: String {
            let hours = minute / 60
            let minutes = minute % 60
            if hours > 0, minutes > 0 { return "~\(hours)h \(minutes)m" }
            if hours > 0 { return "~\(hours)h" }
            return "~\(minutes)m"
        }
    }

    let title: String
    let detail: String
    let symbol: String
    let color: Color
    let stops: [Stop]

    init(route: ScoredRoute, continuousMinutes: Double) {
        let routeMinutes = Double(route.durationSeconds) / 60
        let highDemand = (route.routeDemands ?? []).contains { demand in
            demand.available && (demand.level == .high || demand.intensity >= 0.66)
        } || route.score >= 70
        let longDrive = routeMinutes >= 90
        let interval = highDemand ? 60 : 90
        let firstBreak = max(30, interval - Int(continuousMinutes.rounded(.down)))
        let breakMinutes = stride(from: firstBreak, through: Int(routeMinutes.rounded(.down)), by: interval)
            .filter { $0 < Int(routeMinutes.rounded(.down)) - 10 }
            .prefix(3)
            .map {
                Stop(
                    minute: $0,
                    reason: highDemand
                        ? "Reset attention before the demanding stretch continues."
                        : "Step out before fatigue builds."
                )
            }

        if longDrive || highDemand || continuousMinutes >= 45 {
            title = highDemand ? "Breaks recommended" : "Long-drive breaks"
            detail = "This route is about \(Self.durationLabel(routeMinutes)). Roam factors in your current continuous driving time and suggests rest timing before you start."
            symbol = "cup.and.saucer.fill"
            color = highDemand ? AppDesign.safety : AppDesign.accent
            stops = Array(breakMinutes)
        } else {
            title = "No planned stop needed"
            detail = "This route is about \(Self.durationLabel(routeMinutes)), so Roam does not recommend an automatic rest stop right now."
            symbol = "checkmark.circle.fill"
            color = AppDesign.positive
            stops = []
        }
    }

    private static func durationLabel(_ minutes: Double) -> String {
        let rounded = Int(minutes.rounded())
        let hours = rounded / 60
        let mins = rounded % 60
        if hours > 0, mins > 0 { return "\(hours) hr \(mins) min" }
        if hours > 0 { return "\(hours) hr" }
        return "\(mins) min"
    }
}

struct PracticeDebriefCard: View {
    @ObservedObject private var theme = ThemeManager.shared
    let drive: RecordedDrive

    private var debrief: PracticeDriveDebrief? {
        drive.plannedRouteContext?.debrief
    }

    private var planGoals: [PracticeGoal] {
        drive.plannedRouteContext?.practicePlan?.goals ?? []
    }

    var body: some View {
        if let debrief {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: AppDesign.space12) {
                    Image(systemName: debriefSymbol)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(debriefColor)
                        .frame(width: 40, height: 40)
                        .background(debriefColor.opacity(0.12), in: RoundedRectangle(cornerRadius: AppDesign.cornerRadiusSmall, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(debrief.headline).font(.headline)
                        Text(debrief.summary)
                            .font(.footnote)
                            .foregroundStyle(AppDesign.Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !debrief.goalCompletions.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: AppDesign.space8) {
                        Text("Practice goals")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppDesign.Ink.secondary)
                        ForEach(debrief.goalCompletions) { completion in
                            let goal = planGoals.first(where: { $0.id == completion.goalID })
                            HStack(alignment: .top, spacing: AppDesign.space8) {
                                Image(systemName: completion.wasMeasuredToday ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(completion.wasMeasuredToday ? AppDesign.positive : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(goal?.title ?? "Practice goal")
                                        .font(.footnote.weight(.semibold))
                                    Text(completion.status.title)
                                        .font(.caption)
                                        .foregroundStyle(AppDesign.Ink.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }

                NavigationLink {
                    DriveDetailView(drive: drive)
                } label: {
                    Label("Review moments", systemImage: "play.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(AppDesign.accent)
            }
            .premiumCard()
        }
    }

    private var debriefColor: Color {
        switch debrief?.outcome {
        case .some(.verifiedRoutePractice):
            return AppDesign.positive
        case .some(.partialRouteCoverage):
            return AppDesign.safety
        case .some(.insufficientGPSCoverage), .some(.savedNotYetQualifying):
            return AppDesign.accent
        case nil:
            return .secondary
        }
    }

    private var debriefSymbol: String {
        switch debrief?.outcome {
        case .some(.verifiedRoutePractice):
            return "checkmark.seal.fill"
        case .some(.partialRouteCoverage):
            return "point.3.connected.trianglepath.dotted"
        case .some(.insufficientGPSCoverage):
            return "location.slash"
        case .some(.savedNotYetQualifying):
            return "chart.bar.xaxis"
        case nil:
            return "checkmark.circle"
        }
    }
}
