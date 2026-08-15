import SwiftUI

/// A single row in the Home screen's recent-routes list: a compact repeat of
/// the trip-header dot/line used on Results, plus the score that route
/// earned, so a driver can spot a route worth avoiding without reopening it.
struct RecentRouteRow: View {
    @ObservedObject private var theme = ThemeManager.shared
    let entry: RecentRouteEntry
    let action: () -> Void

    private var labelColor: Color {
        entry.label.color
    }

    private var relativeTime: String {
        entry.analyzedAt.formatted(.relative(presentation: .named))
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: AppDesign.space12) {
                Text(entry.formattedScore)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(AppDesign.Ink.primary)
                    .frame(width: 44, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.origin)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppDesign.Ink.primary)
                        .lineLimit(1)
                    Text(entry.destination)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppDesign.Ink.primary)
                        .lineLimit(1)
                    Text("\(relativeTime) · \(entry.formattedDuration) · \(entry.formattedDistance)")
                        .font(.caption)
                        .foregroundStyle(AppDesign.Ink.secondary)
                        .lineLimit(1)
                }
                .layoutPriority(1)

                Spacer(minLength: AppDesign.space8)

                Text(entry.label.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(labelColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(labelColor.opacity(0.12), in: Capsule())
            }
            .padding(.horizontal, AppDesign.space16)
            .padding(.vertical, AppDesign.space12)
            .background(AppDesign.cardSurface, in: RoundedRectangle(cornerRadius: AppDesign.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppDesign.cornerRadius, style: .continuous)
                    .stroke(AppDesign.cardStroke, lineWidth: 0.5)
            }
            .elevation(AppDesign.Elevation.low)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableScaleStyle())
        .accessibilityLabel("\(entry.origin) to \(entry.destination), difficulty \(entry.formattedScore), \(entry.label.rawValue), analyzed \(relativeTime)")
        .accessibilityHint("Fills the route planner with this trip")
    }
}

#Preview {
    RecentRouteRow(
        entry: RecentRouteEntry(
            origin: "1200 Congress Ave, Austin, TX",
            destination: "Austin-Bergstrom International Airport",
            departureTime: Date(),
            analyzedAt: Date().addingTimeInterval(-3600),
            score: 6.4,
            label: .hard,
            distanceMeters: 14000,
            durationSeconds: 1400
        ),
        action: {}
    )
    .padding()
}
