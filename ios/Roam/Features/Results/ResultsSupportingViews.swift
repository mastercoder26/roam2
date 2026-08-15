import SwiftUI
import UIKit

struct PracticePlanPreview: View {
    @ObservedObject private var theme = ThemeManager.shared
    let plan: PracticePlan

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: AppDesign.space8) {
                Image(systemName: "target").foregroundStyle(AppDesign.safety)
                Text("Guided practice plan").font(.subheadline.weight(.semibold))
            }
            Text(plan.summary).font(.footnote).foregroundStyle(AppDesign.Ink.secondary)
            ForEach(plan.goals) { goal in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: goal.requiresAdultSupervision ? "figure.and.child.holdinghands" : "checkmark.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(goal.requiresAdultSupervision ? AppDesign.safety : AppDesign.accent)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(goal.title).font(.footnote.weight(.semibold))
                        Text(goal.coachingText).font(.caption).foregroundStyle(AppDesign.Ink.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(12)
        .background(AppDesign.safety.opacity(0.08), in: RoundedRectangle(cornerRadius: AppDesign.cornerRadiusSmall, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: AppDesign.cornerRadiusSmall, style: .continuous).stroke(AppDesign.safety.opacity(0.16), lineWidth: 1) }
        .accessibilityElement(children: .combine)
    }
}

struct DepartureComparisonRow: View {
    @ObservedObject private var theme = ThemeManager.shared
    let candidate: DepartureComparisonCandidateResult
    let isCalmestAvailable: Bool
    let isCurrentDeparture: Bool
    let isUpdating: Bool
    let action: () -> Void

    private var departureLabel: String {
        guard let date = candidate.departureDate else { return "Time unavailable" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        Group {
            if let route = candidate.route {
                Button(action: action) {
                    HStack(alignment: .top, spacing: AppDesign.space12) {
                        Image(systemName: isCalmestAvailable ? "leaf.fill" : "clock")
                            .foregroundStyle(isCalmestAvailable ? AppDesign.positive : AppDesign.accent)
                            .frame(width: 28, height: 28)
                            .background((isCalmestAvailable ? AppDesign.positive : AppDesign.accent).opacity(0.12), in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(departureLabel).font(.subheadline.weight(.semibold))
                            Text("Difficulty \(route.formattedScore) · \(route.formattedDuration) · \(route.formattedDistance)")
                                .font(.caption)
                                .foregroundStyle(AppDesign.Ink.secondary)
                            if isCalmestAvailable {
                                Text("Calmest available").font(.caption2.weight(.bold)).foregroundStyle(AppDesign.positive)
                            } else if isCurrentDeparture {
                                Text("Current departure").font(.caption2.weight(.bold)).foregroundStyle(AppDesign.accent)
                            } else if !DepartureComparisonRanking.hasComparableConditions(candidate) {
                                Text("Some comparison conditions are unavailable").font(.caption2).foregroundStyle(AppDesign.Ink.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        if isUpdating && !isCurrentDeparture {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: isCurrentDeparture ? "checkmark.circle.fill" : "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(isCurrentDeparture ? AppDesign.accent : AppDesign.Ink.tertiary)
                        }
                    }
                    .padding(10)
                    .background(isCurrentDeparture ? AppDesign.accent.opacity(0.08) : AppDesign.cardSurfaceElevated, in: RoundedRectangle(cornerRadius: AppDesign.cornerRadiusSmall, style: .continuous))
                }
                .buttonStyle(PressableScaleStyle())
                .disabled(isCurrentDeparture || isUpdating)
                .accessibilityHint(isCurrentDeparture ? "This is the time used for the current route result." : "Refreshes the full route analysis for this departure time.")
            } else {
                HStack(alignment: .top, spacing: AppDesign.space12) {
                    Image(systemName: "clock.badge.exclamationmark").foregroundStyle(AppDesign.Ink.secondary).frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(departureLabel).font(.subheadline.weight(.semibold))
                        Text(candidate.error?.message ?? "This departure time was unavailable.")
                            .font(.caption)
                            .foregroundStyle(AppDesign.Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .background(AppDesign.cardSurfaceElevated, in: RoundedRectangle(cornerRadius: AppDesign.cornerRadiusSmall, style: .continuous))
            }
        }
    }
}

struct ReadinessHistorySummary: View {
    @ObservedObject private var theme = ThemeManager.shared
    let profile: DriverReadinessProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Evidence recorded on this device", systemImage: "lock.shield.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppDesign.Ink.secondary)
            Text("\(profile.qualifyingDriveCount) qualifying \(profile.qualifyingDriveCount == 1 ? "drive" : "drives") · \(String(format: "%.1f", profile.reliableTraceMiles)) validated mi · \(profile.qualifyingDriveDayCount) \(profile.qualifyingDriveDayCount == 1 ? "day" : "days")")
                .font(.footnote.weight(.medium))
                .monospacedDigit()
            VStack(alignment: .leading, spacing: AppDesign.space4) {
                readinessFact("After-dark miles", value: "\(String(format: "%.1f", profile.nightExposure.miles)) mi across \(profile.nightExposure.sessionCount) \(profile.nightExposure.sessionCount == 1 ? "drive" : "drives")", symbol: "moon.stars.fill")
                readinessFact("45+ mph miles", value: "\(String(format: "%.1f", profile.fastRoad45Exposure.miles)) mi across \(profile.fastRoad45Exposure.sessionCount) \(profile.fastRoad45Exposure.sessionCount == 1 ? "drive" : "drives")", symbol: "speedometer")
                readinessFact("Longest continuous trace", value: durationText(profile.longestDriveDuration), symbol: "clock.fill")
            }
        }
        .padding(12)
        .background(AppDesign.cardSurfaceElevated, in: RoundedRectangle(cornerRadius: AppDesign.cornerRadiusSmall, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func readinessFact(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.caption.weight(.semibold)).foregroundStyle(AppDesign.accent).frame(width: 15)
                Text(title).font(.caption).foregroundStyle(AppDesign.Ink.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(value).font(.caption.weight(.medium)).foregroundStyle(AppDesign.Ink.primary).monospacedDigit().fixedSize(horizontal: false, vertical: true).padding(.leading, 22)
        }
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let minutes = max(0, Int((duration / 60).rounded()))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes) min"
    }
}

struct ReadinessInsightRow: View {
    @ObservedObject private var theme = ThemeManager.shared
    let insight: DriverReadinessInsight

    private var color: Color {
        switch insight.state {
        case .matched: AppDesign.positive
        case .practiceNeeded: AppDesign.safety
        case .unmeasured: AppDesign.accent
        case .informational: .secondary
        }
    }

    private var symbol: String {
        switch insight.state {
        case .matched: "checkmark.circle.fill"
        case .practiceNeeded: "figure.and.child.holdinghands"
        case .unmeasured: "questionmark.circle.fill"
        case .informational: "info.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(color).frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(insight.title).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(stateTitle).font(.caption2.weight(.bold)).foregroundStyle(color).textCase(.uppercase)
                Text(insight.detail).font(.footnote).foregroundStyle(AppDesign.Ink.secondary).fixedSize(horizontal: false, vertical: true)
                if let evidence = insight.evidence {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Saved: \(evidence.recordedValue)").font(.caption.weight(.medium)).foregroundStyle(AppDesign.Ink.primary)
                        if let target = evidence.comparisonTarget {
                            Text("Compared with: \(target)").font(.caption).foregroundStyle(AppDesign.Ink.secondary)
                        }
                        if let collectionNote = evidence.collectionNote {
                            Label(collectionNote, systemImage: "info.circle")
                                .font(.caption2)
                                .foregroundStyle(AppDesign.Ink.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 2)
                        }
                    }
                    .padding(.top, 3)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var stateTitle: String {
        switch insight.state {
        case .matched: "Recorded"
        case .practiceNeeded: "Practice"
        case .unmeasured: "Not measured"
        case .informational: "Info"
        }
    }
}

struct RouteDemandRow: View {
    @ObservedObject private var theme = ThemeManager.shared
    let demand: RouteDemand

    private var color: Color {
        switch demand.level {
        case .low: AppDesign.positive
        case .moderate, .high: AppDesign.safety
        }
    }

    private var symbol: String {
        switch demand.kind {
        case .afterDark: "moon.stars.fill"
        case .fastRoads: "speedometer"
        case .merges: "arrow.triangle.merge"
        case .complexIntersections: "arrow.triangle.turn.up.right.diamond.fill"
        case .weatherVisibility: "cloud.sun.rain.fill"
        case .sustainedDrive: "clock.fill"
        case .traffic: "car.2.fill"
        case .roadConditions: "road.lanes"
        case nil: "point.3.connected.trianglepath.dotted"
        }
    }

    private var levelLabel: String {
        switch demand.level {
        case .low: "Low"
        case .moderate: "Elevated"
        case .high: "High"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.space8) {
            HStack(alignment: .top, spacing: AppDesign.space12) {
                Image(systemName: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(color).frame(width: 36, height: 36).background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: AppDesign.cornerRadiusTiny, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: AppDesign.space8) {
                        Text(demand.title).font(.subheadline.weight(.semibold))
                        Text(levelLabel).font(.caption2.weight(.bold)).foregroundStyle(color).padding(.horizontal, 7).padding(.vertical, 3).background(color.opacity(0.12), in: Capsule())
                    }
                    Text(demand.evidence).font(.footnote).foregroundStyle(AppDesign.Ink.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppDesign.cardStrokeStrong)
                    Capsule().fill(color).frame(width: proxy.size.width * demand.intensity)
                }
            }
            .frame(height: 5)
            .accessibilityHidden(true)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

struct BreakdownBarRow: View {
    @ObservedObject private var theme = ThemeManager.shared
    let title: String
    let value: Double
    @State private var displayedValue: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(String(format: "%.0f%%", displayedValue * 100)).font(.subheadline.weight(.medium)).foregroundStyle(AppDesign.Ink.secondary).monospacedDigit().contentTransition(.numericText())
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppDesign.cardStrokeStrong)
                    Capsule().fill(barColor).frame(width: geometry.size.width * min(max(displayedValue, 0), 1))
                }
            }
            .frame(height: 6)
        }
        .onAppear { withAnimation(reduceMotion ? .easeOut(duration: 0.2) : AppAnimation.reveal.delay(0.04)) { displayedValue = value } }
        .onChange(of: value) { _, newValue in
            withAnimation(reduceMotion ? .easeOut(duration: 0.16) : AppAnimation.content) { displayedValue = newValue }
        }
    }

    private var barColor: Color {
        switch displayedValue {
        case 0..<0.35: .green
        case 0.35..<0.65: AppDesign.safety
        default: AppDesign.danger
        }
    }
}

struct ReasonChipView: View {
    @ObservedObject private var theme = ThemeManager.shared
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(AppDesign.Ink.primary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(AppDesign.cardSurfaceElevated, in: RoundedRectangle(cornerRadius: AppDesign.cornerRadiusSmall, style: .continuous))
    }
}

struct ReasonChipFlowLayout: View {
    let reasons: [String]
    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
                ReasonChipView(text: reason)
            }
        }
    }
}

/// A shared wrapping layout for route checks, badges, and explanation chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let intrinsicWidth = subviews.enumerated().reduce(CGFloat.zero) { width, item in
            width + (item.offset == 0 ? 0 : spacing) + item.element.sizeThatFits(.unspecified).width
        }
        let proposedWidth = proposal.width ?? intrinsicWidth
        let maxWidth = max(0, proposedWidth.isFinite ? proposedWidth : intrinsicWidth)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var frames: [CGRect] = []
        for subview in subviews {
            let fitted = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: proposal.height))
            let size = CGSize(width: min(fitted.width, maxWidth), height: fitted.height)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return (CGSize(width: maxWidth, height: y + rowHeight), frames)
    }
}

struct TripDetailsCard: View {
    @ObservedObject private var theme = ThemeManager.shared
    let route: ScoredRoute

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.space12) {
            SectionHeader(title: "Trip at a glance")

            HStack(spacing: AppDesign.space16) {
                DetailTile(
                    title: "ETA",
                    value: route.formattedDuration,
                    systemImage: "clock.fill"
                )

                if let delay = route.formattedDelay {
                    DetailTile(
                        title: "Delay",
                        value: delay,
                        systemImage: "car.fill",
                        valueColor: AppDesign.safety
                    )
                }

                DetailTile(
                    title: "Distance",
                    value: route.formattedDistance,
                    systemImage: "arrow.left.and.right"
                )
            }

            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .foregroundStyle(AppDesign.Ink.secondary)
                Text("Normal drive: \(route.formattedStaticDuration)")
                    .font(.subheadline)
                    .foregroundStyle(AppDesign.Ink.secondary)
            }
        }
        .premiumCard()
    }
}

private struct DetailTile: View {
    @ObservedObject private var theme = ThemeManager.shared
    let title: String
    let value: String
    let systemImage: String
    var valueColor: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.space4) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppDesign.accent)
            Text(value)
                .font(AppDesign.Typography.metricValue)
                .foregroundStyle(valueColor)
                .monospacedDigit()
            Text(title)
                .font(AppDesign.Typography.metricLabel)
                .foregroundStyle(AppDesign.Ink.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RouteConditionsCard: View {
    @ObservedObject private var theme = ThemeManager.shared
    let conditions: RouteConditions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Live conditions")

            if conditions.weather.available {
                HStack(spacing: AppDesign.space12) {
                    Image(systemName: conditions.weather.systemImage)
                        .font(.title2)
                        .symbolRenderingMode(.multicolor)
                        .frame(width: 40, height: 40)
                        .background(AppDesign.cardSurfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: AppDesign.cornerRadiusSmall, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: AppDesign.space8) {
                            Text(conditions.weather.condition)
                                .font(.subheadline.weight(.semibold))
                            severityChip(
                                label: conditions.weather.severityLabel,
                                severity: conditions.weather.severity
                            )
                        }
                        Text(weatherDetailText(conditions.weather))
                            .font(.caption)
                            .foregroundStyle(AppDesign.Ink.secondary)
                    }
                    Spacer()
                }
            }

            if conditions.road.available {
                Divider()
                HStack(spacing: AppDesign.space12) {
                    Image(systemName: "road.lanes")
                        .font(.title2)
                        .foregroundStyle(.blue)
                        .frame(width: 40, height: 40)
                        .background(AppDesign.cardSurfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: AppDesign.cornerRadiusSmall, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(conditions.road.dominantRoadLabel)
                            .font(.subheadline.weight(.semibold))
                        Text(roadDetailText(conditions.road))
                            .font(.caption)
                            .foregroundStyle(AppDesign.Ink.secondary)
                    }
                    Spacer()
                }
            }

            if conditions.road.constructionZones > 0 {
                conditionRow(
                    systemImage: "cone.fill",
                    color: AppDesign.safety,
                    text: conditions.road.constructionZones == 1
                        ? "1 construction zone along the route"
                        : "\(conditions.road.constructionZones) construction zones along the route"
                )
            }

            if conditions.turns.available && conditions.turns.unprotectedLeftTurns > 0 {
                conditionRow(
                    systemImage: "arrow.turn.up.left",
                    color: AppDesign.safety,
                    text: conditions.turns.unprotectedLeftTurns == 1
                        ? "1 unprotected left turn (no signal)"
                        : "\(conditions.turns.unprotectedLeftTurns) unprotected left turns (no signal)"
                )
            }

            if !conditions.sources.isEmpty {
                Divider()
                Label(
                    "Inputs used: \(conditions.sources.map { sourceLabel($0) }.joined(separator: ", "))",
                    systemImage: "checkmark.seal"
                )
                .font(.caption)
                .foregroundStyle(AppDesign.Ink.secondary)
            }
        }
        .premiumCard()
    }

    private func sourceLabel(_ source: String) -> String {
        switch source {
        case "open-meteo": "Open-Meteo weather"
        case "osm-overpass": "OpenStreetMap road data"
        case "google-route-warnings": "Google route advisories"
        default: source
        }
    }

    private func conditionRow(systemImage: String, color: Color, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(color)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
            Spacer()
        }
    }

    private func severityChip(label: String, severity: Double) -> some View {
        let color: Color = severity < 0.15 ? .green : severity < 0.4 ? .yellow : AppDesign.safety
        return Text(label)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func weatherDetailText(_ weather: WeatherConditions) -> String {
        var parts: [String] = [String(format: "%.0f°F", weather.temperatureF)]
        if weather.windGustMph >= 15 {
            parts.append(String(format: "gusts %.0f mph", weather.windGustMph))
        }
        if weather.visibilityMiles > 0 && weather.visibilityMiles < 5 {
            parts.append(String(format: "visibility %.1f mi", weather.visibilityMiles))
        }
        if weather.icyRisk > 0.3 {
            parts.append("ice risk")
        }
        return parts.joined(separator: " · ")
    }

    private func roadDetailText(_ road: RoadConditions) -> String {
        var parts: [String] = []
        if road.avgLanes > 0 {
            parts.append(String(format: "avg %.1f lanes", road.avgLanes))
        }
        if road.majorRoadShare > 0 {
            parts.append(String(format: "%.0f%% major roads", road.majorRoadShare * 100))
        }
        if road.narrowRoadShare >= 0.15 {
            parts.append(String(format: "%.0f%% narrow", road.narrowRoadShare * 100))
        }
        if road.unpavedShare >= 0.05 {
            parts.append(String(format: "%.0f%% unpaved", road.unpavedShare * 100))
        }
        return parts.isEmpty ? "Road data from OpenStreetMap" : parts.joined(separator: " · ")
    }
}

enum MapApp { case appleMaps, googleMaps }

enum RouteNavigationService {
    static func appleMapsURL(origin: String, destination: String) -> URL? {
        url(scheme: "http", host: "maps.apple.com", path: "/", queryItems: [
            URLQueryItem(name: "saddr", value: origin),
            URLQueryItem(name: "daddr", value: destination),
            URLQueryItem(name: "dirflg", value: "d"),
        ])
    }

    static func googleMapsAppURL(origin: String, destination: String) -> URL? {
        url(scheme: "comgooglemaps", host: nil, path: "/", queryItems: [
            URLQueryItem(name: "saddr", value: origin),
            URLQueryItem(name: "daddr", value: destination),
            URLQueryItem(name: "directionsmode", value: "driving"),
        ])
    }

    static func googleMapsWebURL(origin: String, destination: String) -> URL? {
        url(scheme: "https", host: "www.google.com", path: "/maps/dir/", queryItems: [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "origin", value: origin),
            URLQueryItem(name: "destination", value: destination),
            URLQueryItem(name: "travelmode", value: "driving"),
        ])
    }

    static func googleMapsURL(origin: String, destination: String) -> URL? {
        if let appURL = googleMapsAppURL(origin: origin, destination: destination), UIApplication.shared.canOpenURL(appURL) {
            return appURL
        }
        return googleMapsWebURL(origin: origin, destination: destination)
    }

    static var isGoogleMapsInstalled: Bool {
        guard let url = URL(string: "comgooglemaps://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    private static func url(scheme: String, host: String?, path: String, queryItems: [URLQueryItem]) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path
        components.queryItems = queryItems
        return components.url
    }
}
