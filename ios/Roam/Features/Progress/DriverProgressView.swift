import SwiftUI
import UIKit

/// A private view of measured driving evidence and a route-adjusted coaching
/// score. It is never a safety guarantee, driving permission, or ranking.
struct DriverProgressView: View {
    @ObservedObject private var theme = ThemeManager.shared
    @EnvironmentObject private var session: DriveSessionManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.showDriveTab) private var showDriveTab
    @State private var showsMeasurementDetails = false

    private var summary: DriverProgressSummary {
        DriverProgressEngine.makeSummary(from: session.recordedDrives)
    }

    private var performance: DriverPerformanceSummary {
        DriverPerformanceEngine.makeSummary(from: session.recordedDrives)
    }

    /// Saved drives can be high-quality yet still fall short of the minimum
    /// distance or continuous-trace threshold for progress aggregation.
    private var notYetQualifyingDriveCount: Int {
        max(0, session.recordedDrives.count - summary.qualifyingDriveCount)
    }

    private var hasThinRecordedHistory: Bool {
        summary.qualifyingDriveCount < 3 || summary.qualifyingDriveDayCount < 3
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppDesign.sectionSpacing) {
                    ScreenHeader(
                        title: "Progress",
                        symbol: "chart.line.uptrend.xyaxis"
                    )
                    overallScoreCard

                    WeekCadenceStrip(
                        title: "This week",
                        days: CadenceDay.recentWeek(completedDates: session.recordedDrives.map(\.startedAt))
                    )
                    .animation(reduceMotion ? .easeOut(duration: 0.16) : AppAnimation.selection, value: session.recordedDrives.map(\.id))

                    if summary.hasRecordedEvidence {
                        progressOverview
                        if hasThinRecordedHistory {
                            thinEvidenceState
                        }
                        measurementDetailsDisclosure
                    } else {
                        emptyEvidenceState
                    }

                    if notYetQualifyingDriveCount > 0 {
                        notYetQualifyingNote
                    }
                }
                .padding(.horizontal, AppDesign.contentPadding)
                .padding(.vertical, 12)
            }
            .background(AppCanvasBackground())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var overallScoreCard: some View {
        VStack(alignment: .leading, spacing: AppDesign.space12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "steeringwheel.and.heat.waves")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppDesign.primarySurfaceForeground)
                    .frame(width: 42, height: 42)
                    .background(AppDesign.primarySurfaceForeground.opacity(0.14), in: RoundedRectangle(cornerRadius: AppDesign.cornerRadiusSmall, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Overall driving score")
                        .font(.headline)
                        .foregroundStyle(AppDesign.primarySurfaceForeground)
                    Text(performance.evidence.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppDesign.primarySurfaceForeground.opacity(0.7))
                }
                Spacer(minLength: 8)

                if let score = performance.score {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(score)")
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .tracking(-1)
                            .monospacedDigit()
                            .foregroundStyle(AppDesign.primarySurfaceForeground)
                        Text("/100")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AppDesign.primarySurfaceForeground.opacity(0.62))
                    }
                    .accessibilityLabel("Overall driving score \(score) out of 100")
                }
            }

            if let score = performance.score {
                ProgressView(value: Double(score), total: 100)
                    .tint(AppDesign.primarySurfaceForeground)
                    .accessibilityHidden(true)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        performanceSignals
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        performanceSignals
                    }
                }
            }

            Text(performance.detail)
                .font(.footnote)
                .foregroundStyle(AppDesign.primarySurfaceForeground.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppDesign.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppDesign.Ink.primary, in: RoundedRectangle(cornerRadius: AppDesign.cornerRadiusLarge, style: .continuous))
        .elevation(AppDesign.Elevation.hero)
    }

    @ViewBuilder
    private var performanceSignals: some View {
        ProgressScoreSignal(
            value: "\(performance.includedDriveCount)",
            label: performance.includedDriveCount == 1 ? "analyzed drive" : "analyzed drives"
        )
        ProgressScoreSignal(
            value: String(format: "%.1f", performance.measuredMiles),
            label: "analyzed miles"
        )
        if let difficulty = performance.averageDifficulty {
            ProgressScoreSignal(
                value: String(format: "%.1f / 10", difficulty),
                label: "avg. route difficulty"
            )
        }
    }

    private var emptyEvidenceState: some View {
        VStack(alignment: .leading, spacing: AppDesign.space12) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(AppDesign.accent)
                .frame(width: 52, height: 52)
                .background(AppDesign.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            Text("No recorded evidence yet")
                .font(.headline)
            Text("Complete a drive with usable GPS and motion to start building history.")
                .font(.footnote)
                .foregroundStyle(AppDesign.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                UISelectionFeedbackGenerator().selectionChanged()
                showDriveTab()
            } label: {
                Label("Record your first drive", systemImage: "steeringwheel")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(AppDesign.primarySurfaceForeground)
                    .background(AppDesign.Ink.primary, in: RoundedRectangle(cornerRadius: AppDesign.cornerRadiusSmall, style: .continuous))
            }
            .buttonStyle(PressableScaleStyle())
            .accessibilityHint("Opens the Drive tab")
        }
        .premiumCard()
    }

    private var progressOverview: some View {
        VStack(alignment: .leading, spacing: AppDesign.space12) {
            SectionHeader(title: "Measured miles")

            DashboardMetricStrip(metrics: [
                DashboardMetric(value: String(format: "%.1f", summary.validatedMiles), label: "validated miles"),
                DashboardMetric(value: "\(summary.qualifyingDriveCount)", label: "qualifying drives"),
                DashboardMetric(value: "\(summary.qualifyingDriveDayCount)", label: "recorded days")
            ])

            Divider()

            WeeklyMilesChart(weeks: summary.weeklyMeasuredMiles)
                .animation(reduceMotion ? .easeOut(duration: 0.16) : AppAnimation.content, value: summary.weeklyMeasuredMiles)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(chartAccessibilitySummary)
        }
        .premiumCard()
    }

    private var thinEvidenceState: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .foregroundStyle(AppDesign.accent)
            Text("Based only on drives recorded so far.")
                .font(.footnote)
                .foregroundStyle(AppDesign.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(AppDesign.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: AppDesign.cornerRadiusSmall, style: .continuous))
    }

    private var coverageSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.space12) {
            SectionHeader(title: "Measurement coverage")

            ProgressCoverageRow(
                title: "After-dark miles",
                value: String(format: "%.1f mi", summary.afterDarkMiles),
                detail: "Recorded between 8 PM and 6 AM in the drive’s local time zone.",
                symbol: "moon.stars.fill"
            )
            Divider().padding(.leading, 46)
            ProgressCoverageRow(
                title: "45+ mph miles",
                value: String(format: "%.1f mi", summary.milesAt45Plus),
                detail: "Counted only across continuous GPS segments with measured speed.",
                symbol: "speedometer"
            )
            Divider().padding(.leading, 46)
            ProgressCoverageRow(
                title: "Longest continuous trace",
                value: durationText(summary.longestContinuousDuration),
                detail: String(format: "%.1f mi without a GPS gap", summary.longestContinuousDistanceMiles),
                symbol: "point.3.connected.trianglepath.dotted"
            )
        }
    }

    private var measurementDetailsDisclosure: some View {
        VStack(alignment: .leading, spacing: showsMeasurementDetails ? AppDesign.space12 : 0) {
            Button {
                withAnimation(reduceMotion ? .easeOut(duration: 0.16) : AppAnimation.content) {
                    showsMeasurementDetails.toggle()
                }
            } label: {
                HStack(spacing: AppDesign.space12) {
                    Image(systemName: "scope")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppDesign.Ink.secondary)
                        .frame(width: 34, height: 34)
                        .background(AppDesign.trackSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Measurement details")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppDesign.Ink.primary)
                        Text("Night, speed, continuity, and privacy")
                            .font(.caption)
                            .foregroundStyle(AppDesign.Ink.secondary)
                    }

                    Spacer(minLength: AppDesign.space8)

                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppDesign.Ink.tertiary)
                        .rotationEffect(.degrees(showsMeasurementDetails ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableScaleStyle())
            .accessibilityLabel("Measurement details")
            .accessibilityValue(showsMeasurementDetails ? "Expanded" : "Collapsed")
            .accessibilityHint(showsMeasurementDetails ? "Hides measurement coverage" : "Shows measurement coverage")

            if showsMeasurementDetails {
                Divider()
                coverageSection
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                measurementNote
                    .transition(.opacity)
            }
        }
        .padding(14)
        .background(AppDesign.cardSurface, in: RoundedRectangle(cornerRadius: AppDesign.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppDesign.cornerRadius, style: .continuous)
                .stroke(AppDesign.cardStroke, lineWidth: 0.75)
        }
    }

    private var measurementNote: some View {
        Label(
            "Roam keeps driving history, route overlap, and progress calculations on this device.",
            systemImage: "lock.shield.fill"
        )
        .font(.footnote)
        .foregroundStyle(AppDesign.Ink.secondary)
        .padding(.horizontal, 4)
    }

    private var notYetQualifyingNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(AppDesign.safety)
            Text("\(notYetQualifyingDriveCount) \(notYetQualifyingDriveCount == 1 ? "saved drive is" : "saved drives are") not yet qualifying for progress totals: not enough GPS and motion data.")
                .font(.footnote)
                .foregroundStyle(AppDesign.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(AppDesign.safety.opacity(0.10), in: RoundedRectangle(cornerRadius: AppDesign.cornerRadiusSmall, style: .continuous))
    }

    private var chartAccessibilitySummary: String {
        let values = summary.weeklyMeasuredMiles.map {
            "\($0.startDate.formatted(.dateTime.month(.abbreviated).day())): \(String(format: "%.1f", $0.measuredMiles)) miles"
        }
        return "Measured miles over the last eight weeks. " + values.joined(separator: ". ")
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let totalMinutes = max(0, Int((duration / 60).rounded()))
        if totalMinutes >= 60 {
            return "\(totalMinutes / 60)h \(totalMinutes % 60)m"
        }
        return "\(totalMinutes) min"
    }
}

private struct ProgressMetric: View {
    @ObservedObject private var theme = ThemeManager.shared
    let value: String
    let label: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppDesign.accent)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(AppDesign.Ink.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct ProgressScoreSignal: View {
    @ObservedObject private var theme = ThemeManager.shared
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(AppDesign.primarySurfaceForeground)
            Text(label)
                .font(.caption2)
                .foregroundStyle(AppDesign.primarySurfaceForeground.opacity(0.62))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AppDesign.primarySurfaceForeground.opacity(0.10), in: RoundedRectangle(cornerRadius: AppDesign.cornerRadiusTiny, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct ProgressCoverageRow: View {
    @ObservedObject private var theme = ThemeManager.shared
    let title: String
    let value: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppDesign.positive)
                .frame(width: 34, height: 34)
                .background(AppDesign.positive.opacity(0.12), in: RoundedRectangle(cornerRadius: AppDesign.cornerRadiusTiny, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(AppDesign.Ink.secondary)
            }
            Spacer(minLength: 4)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    DriverProgressView()
        .environmentObject(DriveSessionManager())
}
