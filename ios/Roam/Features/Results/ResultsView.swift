import SwiftUI
import UIKit

private enum ResultsPage: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case details = "Details"

    var id: Self { self }

    var accessibilityHint: String {
        switch self {
        case .overview:
            return "Shows the route score, readiness, alternatives, and navigation"
        case .details:
            return "Shows trip facts, route demands, conditions, and score evidence"
        }
    }
}

struct ResultsView: View {
    @ObservedObject private var theme = ThemeManager.shared
    @State private var result: RouteAnalysisResult

    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var driveSession: DriveSessionManager
    @EnvironmentObject private var authSession: AuthSessionStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedRoute: ScoredRoute
    @State private var readinessAssessment: DriverReadinessAssessment
    @State private var routeChoiceRanking: RouteChoiceRanking?
    @State private var routeChoiceCacheKey: RouteChoiceRankingCacheKey?
    @State private var practicePlan: PracticePlan?
    @State private var departureComparison: DepartureComparisonResponse?
    @State private var departureComparisonError: String?
    @State private var isComparingDepartures = false
    @State private var isReanalyzingDeparture = false
    @State private var showsAllReadinessEvidence = false
    @State private var selectedPage: ResultsPage = .overview

    private let apiClient = APIClient()

    init(result: RouteAnalysisResult) {
        _result = State(initialValue: result)
        _selectedRoute = State(initialValue: result.primaryRoute)
        // This initial placeholder is immediately refreshed from the shared
        // local history on appearance. Caching prevents the GPS-overlap work
        // from running repeatedly while SwiftUI lays out this screen.
        _readinessAssessment = State(
            initialValue: DriverReadinessEngine.assess(
                route: result.primaryRoute,
                recordedDrives: []
            )
        )
    }

    private var routeChoices: [RankedRouteChoice] {
        routeChoiceRanking?.choices ?? []
    }

    private var labelColor: Color {
        selectedRoute.label.color
    }

    private var readiness: DriverReadinessAssessment {
        readinessAssessment
    }

    private var driveHistoryIDs: [UUID] {
        driveSession.recordedDrives.map(\.id)
    }

    private var calmestDepartureID: String? {
        guard let departureComparison else { return nil }
        return DepartureComparisonRanking.calmestCandidateID(in: departureComparison.candidates)
    }

    private var visibleRouteDemands: [RouteDemand] {
        (selectedRoute.routeDemands ?? [])
            .filter { demand in
                demand.available && demand.level != .low
            }
            .sorted { $0.intensity > $1.intensity }
    }

    private var orderedReadinessInsights: [DriverReadinessInsight] {
        readiness.insights.sorted { lhs, rhs in
            let leftPriority = readinessPriority(lhs.state)
            let rightPriority = readinessPriority(rhs.state)
            if leftPriority != rightPriority { return leftPriority < rightPriority }
            return lhs.title < rhs.title
        }
    }

    private var featuredReadinessInsights: [DriverReadinessInsight] {
        let actionItems = orderedReadinessInsights.filter {
            $0.state == .practiceNeeded || $0.state == .unmeasured
        }
        guard !showsAllReadinessEvidence else { return orderedReadinessInsights }

        // Never hide a meaningful gap. Only supporting matches are collapsed.
        let remainingSlots = max(0, 4 - actionItems.count)
        let supporting = orderedReadinessInsights.filter {
            $0.state != .practiceNeeded && $0.state != .unmeasured
        }
        return actionItems + supporting.prefix(remainingSlots)
    }

    private var hiddenReadinessInsightCount: Int {
        max(0, orderedReadinessInsights.count - featuredReadinessInsights.count)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppDesign.sectionSpacing) {
                tripRouteHeader
                resultsPagePicker
                selectedPageContent
                    .animation(
                        reduceMotion
                            ? .easeOut(duration: PremiumMotionSpec.reducedFocusTransition.duration)
                            : AppAnimation.focus,
                        value: selectedPage
                    )
            }
            .padding(.horizontal, AppDesign.contentPadding)
            .padding(.vertical, 12)
        }
        .background(AppCanvasBackground())
        .navigationTitle("Results")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            refreshRouteChoices()
            startDepartureComparison()
        }
        .onChange(of: selectedRoute.polyline) { _, _ in
            refreshReadiness()
        }
        .onChange(of: driveHistoryIDs) { _, _ in
            refreshRouteChoices()
        }
        .onChange(of: selectedPage) { _, _ in
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    private var resultsPagePicker: some View {
        Picker("Result view", selection: $selectedPage) {
            ForEach(ResultsPage.allCases) { page in
                Text(page.rawValue).tag(page)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityHint(selectedPage.accessibilityHint)
    }

    @ViewBuilder
    private var selectedPageContent: some View {
        switch selectedPage {
        case .overview:
            VStack(alignment: .leading, spacing: AppDesign.sectionSpacing) {
                scoreSection
                readinessSection
                departureComparisonSection
                routeChoicesSection
                mapSection
                navigationSection
            }
            .transition(resultsPageTransition)

        case .details:
            VStack(alignment: .leading, spacing: AppDesign.sectionSpacing) {
                tripDetailsSection
                routeDemandsSection
                if let conditions = selectedRoute.conditions, !conditions.sources.isEmpty {
                    RouteConditionsCard(conditions: conditions)
                }
                if let hotspots = selectedRoute.hotspots, !hotspots.isEmpty {
                    hotspotsSection(hotspots)
                }
                if selectedRoute.routeDemands == nil {
                    // Keep older backend deployments useful instead of hiding
                    // the prior score explanation while they catch up.
                    breakdownSection
                    if let contributions = selectedRoute.contributions, !contributions.isEmpty {
                        contributionsSection(contributions)
                    }
                    reasonsSection
                }
            }
            .transition(resultsPageTransition)
        }
    }

    private var resultsPageTransition: AnyTransition {
        // The page can contain an interactive map; opacity/scale retains the
        // focus-pull character without blurring that expensive subtree.
        .premiumFocus(reduceMotion: reduceMotion, includesBlur: false)
    }

    private var tripRouteHeader: some View {
        HStack(alignment: .top, spacing: AppDesign.space12) {
            VStack(spacing: 4) {
                Circle()
                    .fill(AppDesign.accent)
                    .frame(width: 8, height: 8)
                Rectangle()
                    .fill(AppDesign.cardStrokeStrong)
                    .frame(width: 2)
                Circle()
                    .fill(AppDesign.Ink.secondary)
                    .frame(width: 8, height: 8)
            }
            .padding(.top, 4)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                Text(result.origin)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppDesign.Ink.primary)
                    .lineLimit(1)
                Text(result.destination)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppDesign.Ink.primary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text(result.departureTime.formatted(date: .abbreviated, time: .shortened))
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppDesign.Ink.secondary)
                .multilineTextAlignment(.trailing)
                .fixedSize()
        }
        .padding(.horizontal, AppDesign.space16)
        .padding(.vertical, AppDesign.space12)
        .background(AppDesign.cardSurface, in: RoundedRectangle(cornerRadius: AppDesign.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppDesign.cornerRadius, style: .continuous)
                .stroke(AppDesign.cardStroke, lineWidth: 0.75)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Trip from \(result.origin) to \(result.destination), departing \(result.departureTime.formatted(date: .abbreviated, time: .shortened))")
    }

    private var scoreSection: some View {
        VStack(spacing: AppDesign.space12) {
            ScoreGaugeView(score: selectedRoute.score, label: selectedRoute.label)

            Text(selectedRoute.label.rawValue)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(labelColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(labelColor.opacity(0.12))
                .clipShape(Capsule())
                .animation(reduceMotion ? .easeOut(duration: 0.16) : AppAnimation.selection, value: selectedRoute.label)

            RouteEvidenceCard(evidence: selectedRoute.uncertainty?.evidence)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .animation(reduceMotion ? .easeOut(duration: 0.16) : AppAnimation.selection, value: selectedRoute.label)
    }

    private var readinessSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(
                title: "Can I drive this?",
                subtitle: "Compared with your recorded drives."
            )

            HStack(alignment: .top, spacing: AppDesign.space12) {
                Image(systemName: readinessSymbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(readinessColor)
                    .frame(width: 42, height: 42)
                    .background(readinessColor.opacity(0.12), in: RoundedRectangle(cornerRadius: AppDesign.cornerRadiusSmall, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(readiness.headline)
                        .font(.headline)
                        .foregroundStyle(AppDesign.Ink.primary)
                    Text(readiness.summary)
                        .font(.footnote)
                        .foregroundStyle(AppDesign.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ReadinessHistorySummary(profile: readiness.profile)

            if !featuredReadinessInsights.isEmpty {
                Divider()
                VStack(spacing: 10) {
                    ForEach(featuredReadinessInsights) { insight in
                        ReadinessInsightRow(insight: insight)
                    }
                }
            }

            if hiddenReadinessInsightCount > 0 || showsAllReadinessEvidence {
                Button {
                    withAnimation(AppAnimation.quick) {
                        showsAllReadinessEvidence.toggle()
                    }
                } label: {
                    Label(
                        showsAllReadinessEvidence
                            ? "Show fewer comparisons"
                            : "See all \(orderedReadinessInsights.count) comparisons",
                        systemImage: showsAllReadinessEvidence
                            ? "chevron.up"
                            : "chevron.down"
                    )
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppDesign.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityHint(
                    showsAllReadinessEvidence
                        ? "Collapses the recorded evidence used in this route comparison."
                        : "Expands the recorded evidence used in this route comparison."
                )
            }

            if let practicePlan, !practicePlan.goals.isEmpty {
                Divider()
                PracticePlanPreview(plan: practicePlan)
            }

            if !(selectedRoute.routeDemands ?? []).isEmpty {
                Divider()
                Button {
                    queuePracticeRoute()
                } label: {
                    Label("Practice this route", systemImage: "steeringwheel")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(AppDesign.accentForeground)
                        .background(AppDesign.accent, in: RoundedRectangle(cornerRadius: AppDesign.cornerRadiusSmall, style: .continuous))
                }
                .buttonStyle(PressableScaleStyle())
                .disabled(driveSession.isRecording)
                .opacity(driveSession.isRecording ? 0.55 : 1)
                .accessibilityHint("Prepares this route for your next drive.")
            }

            Label(
                "This is coaching, not a safety guarantee.",
                systemImage: "checkmark.shield"
            )
            .font(.caption)
            .foregroundStyle(AppDesign.Ink.secondary)
        }
        .premiumCard()
        .animation(reduceMotion ? .easeOut(duration: 0.16) : AppAnimation.content, value: selectedRoute.polyline)
    }

    @ViewBuilder
    private var routeDemandsSection: some View {
        if selectedRoute.routeDemands != nil {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(
                    title: "What this route asks of you",
                    subtitle: "The road conditions that stand out for this drive."
                )

                if visibleRouteDemands.isEmpty {
                    Label(
                        "No route demand stands out above its usual range.",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.subheadline)
                    .foregroundStyle(AppDesign.Ink.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(visibleRouteDemands) { demand in
                            RouteDemandRow(demand: demand)
                            if demand.id != visibleRouteDemands.last?.id {
                                Divider().padding(.leading, 48)
                            }
                        }
                    }
                }

                if selectedRoute.routeDemands?.contains(where: { !$0.available }) == true {
                    Label(
                        "Unavailable live road or weather data is left out rather than estimated.",
                        systemImage: "checkmark.shield.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(AppDesign.Ink.secondary)
                }
            }
            .premiumCard()
            .animation(reduceMotion ? .easeOut(duration: 0.16) : AppAnimation.content, value: selectedRoute.polyline)
        }
    }

    private var readinessColor: Color {
        switch readiness.verdict {
        case .looksLikeMatch:
            return AppDesign.positive
        case .practiceWithAdult:
            return AppDesign.safety
        case .insufficientHistory:
            return AppDesign.accent
        }
    }

    private var readinessSymbol: String {
        switch readiness.verdict {
        case .looksLikeMatch:
            return "chart.bar.fill"
        case .practiceWithAdult:
            return "figure.and.child.holdinghands"
        case .insufficientHistory:
            return "road.lanes"
        }
    }

    private func queuePracticeRoute() {
        guard !driveSession.isRecording else { return }
        driveSession.queuePlannedPracticeRoute(selectedRoute, practicePlan: practicePlan)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func readinessPriority(_ state: DriverReadinessInsightState) -> Int {
        switch state {
        case .practiceNeeded: return 0
        case .unmeasured: return 1
        case .matched: return 2
        case .informational: return 3
        }
    }

    private func refreshReadiness() {
        let assessment = DriverReadinessEngine.assess(
            route: selectedRoute,
            recordedDrives: driveSession.recordedDrives
        )
        readinessAssessment = assessment
        practicePlan = PracticePlanEngine.makePlan(assessment: assessment, route: selectedRoute)
        showsAllReadinessEvidence = false
    }

    private func refreshRouteChoices(force: Bool = false) {
        let key = RouteChoiceRankingEngine.cacheKey(
            primaryRoute: result.primaryRoute,
            alternateRoutes: result.alternateRoutes,
            recordedDrives: driveSession.recordedDrives
        )
        guard force || key != routeChoiceCacheKey else {
            refreshReadiness()
            return
        }

        let ranking = RouteChoiceRankingEngine.rank(
            primaryRoute: result.primaryRoute,
            alternateRoutes: result.alternateRoutes,
            recordedDrives: driveSession.recordedDrives
        )
        let selectedID = ranking.selectedRouteID(preserving: selectedRoute.id)
        routeChoiceCacheKey = key
        routeChoiceRanking = ranking
        if let selectedChoice = ranking.choice(for: selectedID) {
            selectedRoute = selectedChoice.route
            readinessAssessment = selectedChoice.assessment
            practicePlan = PracticePlanEngine.makePlan(
                assessment: selectedChoice.assessment,
                route: selectedChoice.route
            )
        } else {
            refreshReadiness()
        }
        showsAllReadinessEvidence = false
    }

    private func selectRouteChoice(_ choice: RankedRouteChoice) {
        guard selectedRoute.id != choice.route.id else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.16) : AppAnimation.selection) {
            selectedRoute = choice.route
            readinessAssessment = choice.assessment
            practicePlan = PracticePlanEngine.makePlan(assessment: choice.assessment, route: choice.route)
            showsAllReadinessEvidence = false
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func startDepartureComparison() {
        let current = result
        isComparingDepartures = true
        departureComparisonError = nil
        departureComparison = nil

        Task {
            do {
                let response = try await authSession.performAuthenticated { token in
                    try await apiClient.compareDepartureTimes(
                        origin: current.origin,
                        destination: current.destination,
                        selectedDeparture: current.departureTime,
                        accessToken: token
                    )
                }
                guard result.origin == current.origin,
                      result.destination == current.destination,
                      result.departureTime == current.departureTime else {
                    return
                }
                departureComparison = response
            } catch {
                guard result.origin == current.origin,
                      result.destination == current.destination,
                      result.departureTime == current.departureTime else {
                    return
                }
                departureComparisonError = error.localizedDescription
            }
            guard result.origin == current.origin,
                  result.destination == current.destination,
                  result.departureTime == current.departureTime else {
                return
            }
            isComparingDepartures = false
        }
    }

    private func reanalyze(at candidate: DepartureComparisonCandidateResult) {
        guard let departure = candidate.departureDate,
              !isReanalyzingDeparture else { return }
        let current = result
        isReanalyzingDeparture = true

        Task {
            do {
                let response = try await authSession.performAuthenticated { token in
                    try await apiClient.analyzeRoute(
                        origin: current.origin,
                        destination: current.destination,
                        departureTime: departure,
                        accessToken: token,
                        includeAlternates: true
                    )
                }
                let updated = RouteAnalysisResult(
                    origin: current.origin,
                    destination: current.destination,
                    departureTime: departure,
                    primaryRoute: response.primaryRoute,
                    alternateRoutes: response.alternateRoutes
                )
                withAnimation(reduceMotion ? .easeOut(duration: 0.16) : AppAnimation.content) {
                    result = updated
                    selectedRoute = response.primaryRoute
                    routeChoiceRanking = nil
                    routeChoiceCacheKey = nil
                }
                refreshRouteChoices(force: true)
                startDepartureComparison()
            } catch {
                departureComparisonError = "Could not refresh this departure time. \(error.localizedDescription)"
            }
            isReanalyzingDeparture = false
        }
    }

    private var mapSection: some View {
        RouteMapView(
            polyline: selectedRoute.polyline,
            bounds: selectedRoute.bounds,
            routeColor: UIColor(labelColor)
        )
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: AppDesign.cornerRadius, style: .continuous))
        .elevation(AppDesign.Elevation.low)
        .animation(reduceMotion ? .easeOut(duration: 0.16) : AppAnimation.selection, value: selectedRoute.polyline)
    }

    private var tripDetailsSection: some View {
        TripDetailsCard(route: selectedRoute)
    }

    private var navigationSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.space12) {
            SectionHeader(title: "Start navigation")

            HStack(spacing: AppDesign.space12) {
                Button {
                    openInAppleMaps()
                } label: {
                    Label("Apple Maps", systemImage: "map.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppDesign.accent)

                Button {
                    openInGoogleMaps()
                } label: {
                    Label("Google Maps", systemImage: "globe.americas.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
            }
        }
        .premiumCard()
    }

    private func openInAppleMaps() {
        guard let url = RouteNavigationService.appleMapsURL(
            origin: result.origin,
            destination: result.destination
        ) else { return }
        openURL(url)
    }

    private func openInGoogleMaps() {
        guard let url = RouteNavigationService.googleMapsURL(
            origin: result.origin,
            destination: result.destination
        ) else { return }
        openURL(url)
    }

    private func hotspotsSection(_ hotspots: [SegmentHotspot]) -> some View {
        VStack(alignment: .leading, spacing: AppDesign.space12) {
            SectionHeader(title: "Difficulty hotspots")

            ForEach(Array(hotspots.prefix(5).enumerated()), id: \.element.id) { _, hotspot in
                HStack(spacing: 10) {
                    Text("#\(hotspot.segmentIndex + 1)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppDesign.accentForeground)
                        .frame(width: 28, height: 28)
                        .background(AppDesign.safety)
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(hotspot.label ?? "Segment \(hotspot.segmentIndex + 1)")
                            .font(.subheadline.weight(.medium))
                        Text(String(format: "Intensity %.0f%%", hotspot.difficulty * 100))
                            .font(.caption)
                            .foregroundStyle(AppDesign.Ink.secondary)
                    }
                    Spacer()
                }
            }
        }
        .premiumCard()
    }

    private var breakdownSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.space12) {
            SectionHeader(title: "Difficulty breakdown")

            ForEach(selectedRoute.breakdown.items, id: \.key) { item in
                BreakdownBarRow(title: item.title, value: item.value)
            }
        }
        .premiumCard()
    }

    private func contributionsSection(_ contributions: [FactorContribution]) -> some View {
        VStack(alignment: .leading, spacing: AppDesign.space12) {
            SectionHeader(title: "Top factors")

            ForEach(contributions.prefix(5)) { entry in
                BreakdownBarRow(
                    title: entry.label,
                    value: entry.share
                )
            }
        }
        .premiumCard()
    }

    private var reasonsSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.space12) {
            SectionHeader(title: "Why this score")

            if selectedRoute.reasons.isEmpty {
                Text("No specific difficulty factors identified for this route.")
                    .font(.subheadline)
                    .foregroundStyle(AppDesign.Ink.secondary)
            } else {
                ReasonChipFlowLayout(reasons: selectedRoute.reasons)
            }
        }
        .premiumCard()
    }

    @ViewBuilder
    private var departureComparisonSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.space12) {
            SectionHeader(
                title: "Calmest departure",
                subtitle: "A comparison of nearby departure times."
            )

            if isComparingDepartures {
                HStack(spacing: 10) {
                    ProgressView().tint(AppDesign.accent)
                    Text("Comparing departure times")
                        .font(.subheadline)
                        .foregroundStyle(AppDesign.Ink.secondary)
                }
                .padding(.vertical, 8)
            } else if let departureComparison {
                ForEach(departureComparison.candidates) { candidate in
                    DepartureComparisonRow(
                        candidate: candidate,
                        isCalmestAvailable: calmestDepartureID == candidate.id,
                        isCurrentDeparture: isCurrentDeparture(candidate),
                        isUpdating: isReanalyzingDeparture
                    ) {
                        reanalyze(at: candidate)
                    }
                }
                Label(
                    calmestDepartureID == nil
                        ? "Calmest available needs comparable traffic, after-dark, and weather data for every time."
                        : "Each time uses the best available route at that departure time.",
                    systemImage: "checkmark.shield"
                )
                .font(.caption)
                .foregroundStyle(AppDesign.Ink.secondary)
            } else if let departureComparisonError {
                Label("Departure comparison is unavailable right now. \(departureComparisonError)", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(AppDesign.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .premiumCard()
    }

    private var routeChoicesSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.space12) {
            SectionHeader(
                title: "Route choices",
                subtitle: routeChoiceRanking?.comparisonLimitedByHistory == true
                    ? "Recorded history is still building, so choices are ordered by route difficulty."
                    : "Ranked by route demands and evidence recorded on this device."
            )

            if let ranking = routeChoiceRanking {
                ForEach(ranking.choices) { choice in
                    AlternateRouteCard(
                        route: choice.route,
                        isSelected: choice.route.id == selectedRoute.id,
                        readinessHeadline: choice.assessment.headline,
                        badges: choice.badges,
                        comparisonLimitedByHistory: ranking.comparisonLimitedByHistory
                    ) {
                        selectRouteChoice(choice)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView().tint(AppDesign.accent)
                    Text("Preparing route choices")
                        .font(.subheadline)
                        .foregroundStyle(AppDesign.Ink.secondary)
                }
                .padding(.vertical, 8)
            }
        }
        .premiumCard()
    }

    private func isCurrentDeparture(_ candidate: DepartureComparisonCandidateResult) -> Bool {
        guard let date = candidate.departureDate else { return false }
        return abs(date.timeIntervalSince(result.departureTime)) < 1
    }

}

#Preview {
    NavigationStack {
        ResultsView(
            result: RouteAnalysisResult(
                origin: "Miami, FL",
                destination: "Orlando, FL",
                departureTime: Date().addingTimeInterval(15 * 60),
                primaryRoute: ScoredRoute(
                    score: 4.2,
                    uncalibratedScore: 4.0,
                    label: .moderate,
                    reasons: ["Mostly highway", "Light traffic"],
                    breakdown: DifficultyBreakdown(
                        speed: 0.30, merges: 0.15, turns: 0.35, traffic: 0.15,
                        length: 0.45, fatigue: 0.20, weather: 0.35, road: 0.15,
                        highway: 0.30, maneuvers: 0.35, navDensity: 0.20, effort: 0.45
                    ),
                    contributions: [
                        FactorContribution(
                            factor: "speed",
                            label: "High-speed road burden",
                            value: 0.30,
                            weight: 0.24,
                            contribution: 0.072,
                            share: 0.35
                        ),
                        FactorContribution(
                            factor: "length",
                            label: "Length/monotony burden",
                            value: 0.45,
                            weight: 0.14,
                            contribution: 0.063,
                            share: 0.26
                        )
                    ],
                    uncertainty: ScoreUncertainty(low: 3.6, high: 4.8, confidence: 0.75, spread: 1.2, evidence: nil),
                    hotspots: [],
                    conditions: RouteConditions(
                        weather: WeatherConditions(
                            available: true, condition: "Rain", severity: 0.45,
                            precipIntensity: 0.5, snowRisk: 0, windSeverity: 0.2,
                            lowVisibilityRisk: 0.1, icyRisk: 0, temperatureF: 54,
                            windGustMph: 22, visibilityMiles: 4.5
                        ),
                        road: RoadConditions(
                            available: true, avgLanes: 2.6, narrowRoadShare: 0.1,
                            majorRoadShare: 0.8, unpavedShare: 0, roadSizeScore: 0.2,
                            constructionZones: 1, dominantRoadClass: "motorway"
                        ),
                        turns: TurnExposure(
                            available: true, unprotectedLeftTurns: 2,
                            protectedLeftTurns: 3, unprotectedTurnShare: 0.4
                        ),
                        sources: ["open-meteo", "osm-overpass"]
                    ),
                    modelVersion: "hybrid-v5",
                    distanceMeters: 312000,
                    durationSeconds: 10800,
                    staticDurationSeconds: 9900,
                    trafficDelaySeconds: 900,
                    polyline: "_p~iF~ps|U_ulLnnqC_mqNvxq`@",
                    bounds: RouteBounds(
                        southwest: Coordinate(latitude: 30.2, longitude: -97.8),
                        northeast: Coordinate(latitude: 32.8, longitude: -96.8)
                    ),
                    scoreDelta: nil,
                    routeDemands: [
                        RouteDemand(
                            id: "afterDark",
                            intensity: 0.85,
                            level: .high,
                            evidence: "Most of the drive falls in the 8 PM to 6 AM window.",
                            available: true
                        ),
                        RouteDemand(
                            id: "fastRoads",
                            intensity: 0.68,
                            level: .high,
                            evidence: "72% of the route is estimated at 45+ mph.",
                            available: true
                        ),
                        RouteDemand(
                            id: "merges",
                            intensity: 0.56,
                            level: .moderate,
                            evidence: "2 ramps or merge transitions appear in the route instructions.",
                            available: true
                        )
                    ]
                ),
                alternateRoutes: []
            )
        )
    }
    .environmentObject(DriveSessionManager())
}
