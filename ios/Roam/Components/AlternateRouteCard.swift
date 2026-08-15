import SwiftUI

struct AlternateRouteCard: View {
    @ObservedObject private var theme = ThemeManager.shared
    let route: ScoredRoute
    let isSelected: Bool
    var readinessHeadline: String? = nil
    var badges: [RouteChoiceBadge] = []
    var comparisonLimitedByHistory = false
    let onSelect: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accentColor: Color {
        route.label.color
    }

    private var readinessColor: Color {
        if readinessHeadline == DriverReadinessVerdict.looksLikeMatch.title {
            return AppDesign.positive
        }
        if readinessHeadline == DriverReadinessVerdict.practiceWithAdult.title {
            return AppDesign.safety
        }
        return AppDesign.accent
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: AppDesign.space4) {
                    HStack(spacing: AppDesign.space8) {
                        Text(route.formattedScore)
                            .font(.title3.weight(.bold).monospacedDigit())
                            .foregroundStyle(accentColor)
                            .contentTransition(.numericText())

                        Text(route.label.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppDesign.Ink.secondary)
                    }

                    if let topReason = route.reasons.first {
                        Text(topReason)
                            .font(.subheadline)
                            .foregroundStyle(AppDesign.Ink.primary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let readinessHeadline {
                        Text(readinessHeadline)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(comparisonLimitedByHistory ? .secondary : readinessColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: AppDesign.space12) {
                        Label(route.formattedDuration, systemImage: "clock")
                        Label(route.formattedDistance, systemImage: "arrow.left.and.right")
                    }
                    .font(.caption)
                    .foregroundStyle(AppDesign.Ink.secondary)

                    if !badges.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(badges, id: \.rawValue) { badge in
                                Text(badge.title)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(badge == .bestFit ? AppDesign.positive : AppDesign.accent)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .background((badge == .bestFit ? AppDesign.positive : AppDesign.accent).opacity(0.11), in: Capsule())
                            }
                        }
                    }
                }
                .layoutPriority(1)

                Spacer(minLength: 0)

                if let delta = route.scoreDelta {
                    Text(deltaText(delta))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(delta >= 0 ? AppDesign.safety : AppDesign.positive)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(AppDesign.cardSurfaceElevated)
                        .clipShape(Capsule())
                }

                Image(systemName: isSelected ? "checkmark.circle.fill" : "chevron.right")
                    .font(.body.weight(.medium))
                    .foregroundStyle(isSelected ? AppDesign.accent : AppDesign.Ink.tertiary)
                    .animation(AppAnimation.quick, value: isSelected)
            }
            .padding(AppDesign.cardPadding)
            .background(
                isSelected
                    ? AppDesign.accent.opacity(0.08)
                    : AppDesign.cardSurface
            )
            .clipShape(RoundedRectangle(cornerRadius: AppDesign.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppDesign.cornerRadius, style: .continuous)
                    .strokeBorder(isSelected ? AppDesign.accent.opacity(0.5) : AppDesign.cardStroke, lineWidth: isSelected ? 1.5 : 0.5)
            )
        }
        .buttonStyle(PressableScaleStyle())
        .animation(reduceMotion ? .easeOut(duration: 0.16) : AppAnimation.selection, value: isSelected)
        .accessibilityLabel("Route, score \(route.formattedScore), \(route.label.rawValue)\(readinessHeadline.map { ", \($0)" } ?? "")")
    }

    private func deltaText(_ delta: Double) -> String {
        let sign = delta >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.1f", delta))"
    }
}

#Preview {
    AlternateRouteCard(
        route: ScoredRoute(
            score: 5.1,
            uncalibratedScore: 5.0,
            label: .moderate,
            reasons: ["Many turns"],
            breakdown: DifficultyBreakdown(
                speed: 0.3, merges: 0.2, turns: 0.6, traffic: 0.2,
                length: 0.3, fatigue: 0.1, weather: nil, road: nil,
                highway: 0.3, maneuvers: 0.6, navDensity: 0.4, effort: 0.3
            ),
            contributions: nil,
            uncertainty: ScoreUncertainty(low: 4.5, high: 5.7, confidence: 0.7, spread: 1.2, evidence: nil),
            hotspots: nil,
            conditions: nil,
            modelVersion: nil,
            distanceMeters: 12000,
            durationSeconds: 1800,
            staticDurationSeconds: 1500,
            trafficDelaySeconds: 300,
            polyline: "abc",
            bounds: RouteBounds(
                southwest: Coordinate(latitude: 30.0, longitude: -97.0),
                northeast: Coordinate(latitude: 30.5, longitude: -97.5)
            ),
            scoreDelta: 0.9,
            routeDemands: nil
        ),
        isSelected: false,
        readinessHeadline: "Practice this with an adult",
        onSelect: {}
    )
    .padding()
}
