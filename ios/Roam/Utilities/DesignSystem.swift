import Charts
import SwiftUI

// AppDesign tokens are static reads off a cached palette, so SwiftUI records no
// dependency on them and a view keeps its old colors after a theme switch.
// Anything that paints with a token needs:
//
//     @ObservedObject private var theme = ThemeManager.shared
//
// It is unread in most bodies — it only registers the invalidation dependency.
// Don't remove it as unused.

// MARK: - Tokens

enum AppDesign {
    private static var palette: ThemePalette {
        ThemeManager.cachedPalette
    }

    static var accent: Color { palette.accent.color }
    /// Black or white, whichever reads on an accent-filled control.
    static var accentForeground: Color { palette.accentForeground.color }
    static var safety: Color { palette.safety.color }
    /// Ending a drive, deleting history.
    static var danger: Color { palette.danger.color }
    static var dangerForeground: Color { palette.dangerForeground.color }
    static var positive: Color { palette.positive.color }

    static var canvas: Color { palette.canvas.color }
    static var cardSurface: Color { palette.cardSurface.color }
    /// Map and featured panels, one step above `cardSurface`.
    static var cardSurfaceElevated: Color { palette.cardSurfaceElevated.color }
    static var cardStroke: Color { palette.cardStroke.color }
    static var cardStrokeStrong: Color { palette.cardStrokeStrong.color }
    static var cardShadow: Color { palette.cardShadow.color }
    /// Present-but-unavailable controls.
    static var disabledSurface: Color { palette.disabledSurface.color }
    /// Unfilled portion of meters and progress bars, and chip fills sitting on a card.
    static var trackSurface: Color { palette.cardStroke.color }
    static var glassHighlight: Color { palette.glassHighlight.color }
    static var primarySurfaceForeground: Color { palette.primarySurfaceForeground.color }
    /// High-contrast ink for the flip clock. The timer is rendered on its own
    /// dark plate, so it must be chosen against that plate rather than the
    /// surrounding canvas or a general text hierarchy.
    static var flipClockDigit: Color {
        RGBA.readableForeground(over: palette.cardSurface).color
    }

    /// MapKit overlays and annotations can't take a SwiftUI `Color`.
    enum UIKitColor {
        static var accent: UIColor { AppDesign.palette.accent.uiColor }
        static var safety: UIColor { AppDesign.palette.safety.uiColor }
        static var cardSurface: UIColor { AppDesign.palette.cardSurface.uiColor }
    }

    static let space2: CGFloat = 2
    static let space4: CGFloat = 4
    static let space8: CGFloat = 8
    static let space12: CGFloat = 12
    static let space16: CGFloat = 16
    static let space20: CGFloat = 20
    static let space24: CGFloat = 24
    static let space32: CGFloat = 32

    /// Radius ladder — keep cards, buttons and pills on these rungs.
    static let cornerRadius: CGFloat = 16
    static let cornerRadiusSmall: CGFloat = 11
    static let cornerRadiusLarge: CGFloat = 20
    static let cornerRadiusHero: CGFloat = 22
    /// Icon tiles and other sub-32pt chips, which read as over-rounded at 12.
    static let cornerRadiusTiny: CGFloat = 10

    /// Shadow tiers, all derived from the theme's own shadow color so a dark
    /// scheme never inherits a light scheme's invisible shadow.
    enum Elevation {
        /// Chips and rows sitting directly on a card.
        static let low = (radius: CGFloat(5), y: CGFloat(2), opacity: 0.35)
        /// Cards lifted off the canvas.
        static let medium = (radius: CGFloat(10), y: CGFloat(4), opacity: 0.5)
        /// Floating chrome — tab bar, map panels.
        static let high = (radius: CGFloat(16), y: CGFloat(7), opacity: 0.65)
        /// Hero surfaces that should read as the focal point of a screen.
        static let hero = (radius: CGFloat(18), y: CGFloat(8), opacity: 0.7)
    }

    static let cardPadding: CGFloat = 18
    static let sectionSpacing: CGFloat = 28
    static let contentPadding: CGFloat = 20
    /// Clearance below the last element on a scrolling tab so it clears the
    /// floating tab bar.
    static let tabBarClearance: CGFloat = 44

    enum Ink {
        static var primary: Color { AppDesign.palette.inkPrimary.color }
        static var secondary: Color { AppDesign.palette.inkSecondary.color }
        static var tertiary: Color { AppDesign.palette.inkTertiary.color }
        /// Micro-labels (FROM / TO).
        static var label: Color { AppDesign.palette.inkLabel.color }
    }

    enum Typography {
        /// Screen-opening statement. Tight and heavy, in the manner of a big
        /// consumer app's first line of copy.
        static let display = Font.system(size: 34, weight: .bold, design: .default)
        static let heroTitle = Font.system(.largeTitle, design: .rounded, weight: .bold)
        static let sectionTitle = Font.system(size: 20, weight: .semibold)
        static let railTitle = Font.system(size: 17, weight: .semibold)
        static let metricValue = Font.system(size: 22, weight: .semibold)
        static let metricLabel = Font.caption
        static let body = Font.system(.body, design: .default, weight: .regular)
        static let bodyEmphasized = Font.system(.body, design: .default, weight: .medium)
        /// All-caps micro-label. Pair with `.tracking(1.1)`.
        static let microLabel = Font.caption.weight(.bold)
    }

}

// MARK: - App atmosphere

/// A stable canvas shared by every tab. Depth belongs to functional surfaces,
/// not decorative light fields behind the content.
struct AppCanvasBackground: View {
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        AppDesign.canvas.ignoresSafeArea()
    }
}

// MARK: - Difficulty color

extension DifficultyLabel {
    private var step: DifficultyStep {
        switch self {
        case .veryEasy: .veryEasy
        case .easy: .easy
        case .moderate: .moderate
        case .hard: .hard
        case .veryHard: .veryHard
        }
    }

    var color: Color {
        ThemeManager.cachedPalette.difficultyColor(step).color
    }
}

// MARK: - Card surfaces

struct PremiumCardModifier: ViewModifier {
    @ObservedObject private var theme = ThemeManager.shared

    func body(content: Content) -> some View {
        content
            .padding(AppDesign.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppDesign.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppDesign.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppDesign.cornerRadius, style: .continuous)
                    .stroke(AppDesign.cardStroke, lineWidth: 0.5)
            }
            .elevation(AppDesign.Elevation.low)
    }
}

/// Featured surface. Hierarchy comes from scale and whitespace, not effects.
struct HeroCardModifier: ViewModifier {
    @ObservedObject private var theme = ThemeManager.shared

    func body(content: Content) -> some View {
        content
            .padding(AppDesign.space20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppDesign.cardSurfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: AppDesign.cornerRadiusHero, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppDesign.cornerRadiusHero, style: .continuous)
                    .stroke(AppDesign.cardStrokeStrong, lineWidth: 0.5)
            }
            .elevation(AppDesign.Elevation.hero)
    }
}

extension View {
    func premiumCard() -> some View {
        modifier(PremiumCardModifier())
    }

    func heroCard() -> some View {
        modifier(HeroCardModifier())
    }

    /// Themed shadow. Use instead of a literal `.shadow(color: .black…)`, which
    /// can't adapt and vanishes on dark schemes.
    func elevation(_ tier: (radius: CGFloat, y: CGFloat, opacity: Double)) -> some View {
        shadow(
            color: AppDesign.cardShadow.opacity(tier.opacity),
            radius: tier.radius,
            y: tier.y
        )
    }

    /// Rounded surface with a hairline edge, for content that supplies its own
    /// padding — maps, charts, image panels.
    func surfaceFrame(radius: CGFloat = AppDesign.cornerRadiusLarge, elevated: Bool = true) -> some View {
        clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(AppDesign.cardStroke, lineWidth: 0.75)
            }
            .elevation(elevated ? AppDesign.Elevation.medium : AppDesign.Elevation.low)
    }
}

// MARK: - Headers

struct SectionHeader: View {
    @ObservedObject private var theme = ThemeManager.shared
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.space4) {
            Text(title)
                .font(AppDesign.Typography.sectionTitle)
                .foregroundStyle(AppDesign.Ink.primary)
            if let subtitle {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(AppDesign.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Shared top-of-screen title geometry. Keeping it here stops one tab from
/// inheriting a tall navigation-bar inset while another starts under the brand.
struct ScreenHeader: View {
    @ObservedObject private var theme = ThemeManager.shared
    let title: String
    let symbol: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppDesign.space12) {
            Text(title)
                .font(.system(size: 31, weight: .bold, design: .rounded))
                .tracking(-1.1)
                .foregroundStyle(AppDesign.Ink.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: AppDesign.space8)

            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppDesign.Ink.tertiary)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Rail title with an optional trailing action, the pattern every large
/// consumer app uses above a horizontal carousel.
struct RailHeader<Trailing: View>: View {
    @ObservedObject private var theme = ThemeManager.shared
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(AppDesign.Typography.railTitle)
                .foregroundStyle(AppDesign.Ink.primary)
            Spacer(minLength: AppDesign.space8)
            trailing
        }
    }
}

extension RailHeader where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

struct BrandWordmark: View {
    // Observed directly: safeAreaInset content doesn't always inherit an
    // EnvironmentObject from the modified ancestor, which crashed launch.
    @ObservedObject private var themeManager = ThemeManager.shared
    var compact = false

    var body: some View {
        RoamWordmark(
            fontSize: compact ? 23 : 36,
            foreground: themeManager.palette.inkPrimary.color.opacity(0.92)
        )
            // Hold the compact wordmark at a stable optical size so an
            // accessibility text setting leaves room for the route inputs.
            .dynamicTypeSize(compact ? .large : .accessibility5)
            .contentShape(Rectangle())
    }
}

// MARK: - Buttons

struct PressableScaleStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(AppAnimation.press, value: configuration.isPressed)
    }
}

struct PrimaryActionButton: View {
    let title: String
    let isLoading: Bool
    let isEnabled: Bool
    let action: () -> Void
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isLoading {
                    ProgressView()
                        .tint(isEnabled ? AppDesign.accentForeground : AppDesign.Ink.tertiary)
                        .transition(.opacity)
                }
                Text(isLoading ? "Analyzing…" : title)
                    .font(.body.weight(.semibold))
                    .contentTransition(.interpolate)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .foregroundStyle(isEnabled ? AppDesign.accentForeground : AppDesign.Ink.tertiary)
            .background(
                Capsule()
                    .fill(isEnabled ? AppDesign.accent : AppDesign.disabledSurface)
            )
            .shadow(
                color: isEnabled ? AppDesign.accent.opacity(0.28) : .clear,
                radius: 14,
                y: 6
            )
        }
        .buttonStyle(PressableScaleStyle())
        .disabled(!isEnabled)
        .animation(AppAnimation.quick, value: isLoading)
    }
}

/// Secondary action: outlined, same height as the primary so the two can sit
/// side by side without looking mismatched.
struct SecondaryActionButton: View {
    let title: String
    var symbol: String?
    let action: () -> Void
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppDesign.space8) {
                if let symbol {
                    Image(systemName: symbol)
                }
                Text(title)
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .foregroundStyle(AppDesign.Ink.primary)
            .background(
                Capsule()
                    .fill(AppDesign.cardSurface)
            )
            .overlay {
                Capsule()
                    .stroke(AppDesign.cardStrokeStrong, lineWidth: 1)
            }
        }
        .buttonStyle(PressableScaleStyle())
    }
}

// MARK: - Chips and tiles

struct IconTile: View {
    let symbol: String
    /// `nil` follows the theme accent, resolved at render time. A default
    /// argument would freeze the accent at construction and survive a theme
    /// switch.
    var color: Color?
    var size: CGFloat = 34
    @ObservedObject private var theme = ThemeManager.shared

    private var resolvedColor: Color { color ?? AppDesign.accent }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(resolvedColor)
            .frame(width: size, height: size)
            .background(
                resolvedColor.opacity(0.14),
                in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            )
    }
}

/// Small status tag — "Preliminary", "Verified", a difficulty word.
struct StatusBadge: View {
    let text: String
    var symbol: String?
    var tint: Color?
    @ObservedObject private var theme = ThemeManager.shared

    private var resolvedTint: Color { tint ?? AppDesign.accent }

    var body: some View {
        HStack(spacing: AppDesign.space4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption2.weight(.bold))
            }
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(resolvedTint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(resolvedTint.opacity(0.14), in: Capsule())
    }
}

/// Selectable pill, as used for filter rows.
struct FilterChip: View {
    let title: String
    var symbol: String?
    let isSelected: Bool
    let action: () -> Void
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppDesign.space4) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.caption.weight(.bold))
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(isSelected ? AppDesign.primarySurfaceForeground : AppDesign.Ink.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background {
                Capsule()
                    .fill(isSelected ? AppDesign.Ink.primary : AppDesign.cardSurface)
            }
            .overlay {
                Capsule()
                    .stroke(isSelected ? .clear : AppDesign.cardStroke, lineWidth: 1)
            }
        }
        .buttonStyle(PressableScaleStyle())
        .animation(AppAnimation.selection, value: isSelected)
    }
}

struct StatRow: View {
    let title: String
    let value: String
    let symbol: String
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        HStack(spacing: AppDesign.space12) {
            IconTile(symbol: symbol)
            Text(title).font(.subheadline).foregroundStyle(AppDesign.Ink.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppDesign.Ink.primary)
                .monospacedDigit()
        }
    }
}

/// Number-first tile for a metric grid. Value on top, label beneath, so a row
/// of them scans as data rather than as prose.
struct MetricTile: View {
    let value: String
    let label: String
    var symbol: String?
    var tint: Color?
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.space8) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(tint ?? AppDesign.accent)
            }
            Text(value)
                .font(AppDesign.Typography.metricValue)
                .foregroundStyle(AppDesign.Ink.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(AppDesign.Typography.metricLabel)
                .foregroundStyle(AppDesign.Ink.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppDesign.space16)
        .background(AppDesign.cardSurface, in: RoundedRectangle(cornerRadius: AppDesign.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppDesign.cornerRadius, style: .continuous)
                .stroke(AppDesign.cardStroke, lineWidth: 0.75)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

/// Number-first dashboard data, inspired by fitness summaries: the value does
/// the talking and the label stays quiet. Used across Drive, Progress and
/// Profile so those screens scan as one product.
struct DashboardMetric: Identifiable {
    let id: String
    let value: String
    let label: String

    init(id: String? = nil, value: String, label: String) {
        self.id = id ?? label
        self.value = value
        self.label = label
    }
}

struct DashboardMetricStrip: View {
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let metrics: [DashboardMetric]

    private var usesStackedLayout: Bool {
        LayoutResponsiveness.stacksDashboardMetrics(
            availableWidth: .greatestFiniteMagnitude,
            usesLargeText: dynamicTypeSize.isAccessibilitySize
        )
    }

    var body: some View {
        Group {
            if usesStackedLayout {
                VStack(spacing: AppDesign.space8) { metricViews }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: AppDesign.space8) { metricViews }
                    VStack(spacing: AppDesign.space8) { metricViews }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var metricViews: some View {
        ForEach(metrics) { metric in
            VStack(alignment: .leading, spacing: 2) {
                Text(metric.value)
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .tracking(-0.45)
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .foregroundStyle(AppDesign.Ink.primary)
                Text(metric.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppDesign.Ink.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppDesign.space12)
            .padding(.vertical, AppDesign.space12)
            .background(AppDesign.trackSurface.opacity(0.72), in: RoundedRectangle(cornerRadius: AppDesign.cornerRadiusSmall, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(metric.label): \(metric.value)")
        }
    }
}

struct CadenceDay: Identifiable {
    let id: Date
    let shortLabel: String
    let accessibilityLabel: String
    let isComplete: Bool
    let isToday: Bool

    static func recentWeek(
        completedDates: [Date],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [CadenceDay] {
        let today = calendar.startOfDay(for: now)
        let completed = Set(completedDates.map { calendar.startOfDay(for: $0) })
        let weekdaySymbols = calendar.veryShortWeekdaySymbols

        return (-6...0).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            let weekday = calendar.component(.weekday, from: date)
            return CadenceDay(
                id: date,
                shortLabel: weekdaySymbols[weekday - 1],
                accessibilityLabel: date.formatted(.dateTime.weekday(.wide).month(.wide).day()),
                isComplete: completed.contains(date),
                isToday: calendar.isDate(date, inSameDayAs: today)
            )
        }
    }
}

/// A compact seven-day rhythm strip. Completed days use the product ink while
/// today keeps an accent ring, allowing the state to survive every theme.
struct WeekCadenceStrip: View {
    @ObservedObject private var theme = ThemeManager.shared
    let title: String
    let days: [CadenceDay]

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.space12) {
            HStack {
                Text(title)
                    .font(AppDesign.Typography.railTitle)
                    .foregroundStyle(AppDesign.Ink.primary)
                Spacer(minLength: AppDesign.space8)
                Text("\(days.filter(\.isComplete).count) days")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppDesign.Ink.secondary)
            }

            HStack(spacing: AppDesign.space4) {
                ForEach(days) { day in
                    VStack(spacing: AppDesign.space4) {
                        ZStack {
                            Circle()
                                .fill(day.isComplete ? AppDesign.Ink.primary : AppDesign.trackSurface)
                            if day.isComplete {
                                Image(systemName: "checkmark")
                                    .font(.caption2.weight(.black))
                                    .foregroundStyle(AppDesign.primarySurfaceForeground)
                            }
                        }
                        .frame(width: 34, height: 34)
                        .overlay {
                            if day.isToday {
                                Circle().stroke(AppDesign.accent, lineWidth: 2)
                            }
                        }

                        Text(day.shortLabel)
                            .font(.caption2.weight(day.isToday ? .bold : .medium))
                            .foregroundStyle(day.isToday ? AppDesign.Ink.primary : AppDesign.Ink.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(day.accessibilityLabel), \(day.isComplete ? "drive recorded" : "no recorded drive")\(day.isToday ? ", today" : "")")
                }
            }
        }
        .padding(AppDesign.cardPadding)
        .background(AppDesign.cardSurface, in: RoundedRectangle(cornerRadius: AppDesign.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppDesign.cornerRadius, style: .continuous)
                .stroke(AppDesign.cardStroke, lineWidth: 0.75)
        }
    }
}

/// Placeholder block for content that has not arrived. Pulses unless reduced
/// motion is on.
struct SkeletonBlock: View {
    var height: CGFloat = 16
    var cornerRadius: CGFloat = AppDesign.cornerRadiusTiny
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(AppDesign.Ink.primary.opacity(isPulsing ? 0.14 : 0.07))
            .frame(height: height)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
            .accessibilityHidden(true)
    }
}

/// Illustrated empty state — icon, headline, explanation, optional action.
struct EmptyStateView<Action: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var action: Action
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(spacing: AppDesign.space12) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(AppDesign.accent)
                .frame(width: 68, height: 68)
                .background(AppDesign.accent.opacity(0.12), in: Circle())

            Text(title)
                .font(AppDesign.Typography.sectionTitle)
                .foregroundStyle(AppDesign.Ink.primary)
                .multilineTextAlignment(.center)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(AppDesign.Ink.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            action
                .padding(.top, AppDesign.space4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppDesign.space32)
        .padding(.horizontal, AppDesign.space20)
    }
}

extension EmptyStateView where Action == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

// MARK: - Weekly miles chart

/// The eight-week measured-miles bar chart shared by Progress and Profile. Both
/// screens plot the same `DriverProgressWeek` series with the same marks and
/// axes; height is the only dimension a caller may vary.
///
/// `.animation(…)` and `.accessibilityLabel(…)` are left out on purpose: both
/// depend on call-site state, so each screen applies its own.
struct WeeklyMilesChart: View {
    static let defaultHeight: CGFloat = 180

    /// Bar caps, not the icon-tile rung. At 10 the cap domes over and visually
    /// shortens the smallest weeks in an eight-week series.
    static let barCornerRadius: CGFloat = 5

    let weeks: [DriverProgressWeek]
    var height: CGFloat = WeeklyMilesChart.defaultHeight
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        Chart(weeks) { week in
            BarMark(
                x: .value("Week", week.startDate, unit: .weekOfYear),
                y: .value("Measured miles", week.measuredMiles)
            )
            .foregroundStyle(AppDesign.accent.gradient)
            .cornerRadius(Self.barCornerRadius)
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(AppDesign.cardStroke)
                AxisValueLabel {
                    if let miles = value.as(Double.self) {
                        Text(miles, format: .number.precision(.fractionLength(0)))
                            .font(.caption2)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .font(.caption2)
            }
        }
        .frame(height: height)
    }
}

// MARK: - Motion-aware appear

extension View {
    /// Hero entrance: fade plus a small lift. Drops the offset under reduced motion.
    func heroAppear(visible: Bool, delay: Double = 0) -> some View {
        modifier(HeroAppearModifier(visible: visible, delay: delay))
    }
}

private struct HeroAppearModifier: ViewModifier {
    let visible: Bool
    let delay: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : 12)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.2).delay(delay)
                    : AppAnimation.hero.delay(delay),
                value: visible
            )
    }
}
