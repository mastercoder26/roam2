import ActivityKit
import SwiftUI
import WidgetKit

@main
struct RoamDriveActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        RoamDriveActivityWidget()
    }
}

struct RoamDriveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DriveActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "steeringwheel")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Drive in progress")
                        .font(.headline)
                    Text(context.attributes.startedAt, style: .timer)
                        .font(.title3.monospacedDigit().weight(.semibold))
                }

                Spacer(minLength: 10)

                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(context.state.speedMilesPerHour) mph")
                        .font(.headline.monospacedDigit())
                    Text(String(format: "%.1f mi", context.state.distanceMiles))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
            .activityBackgroundTint(Color(.systemBackground))
            .activitySystemActionForegroundColor(.blue)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Roam", systemImage: "steeringwheel")
                        .foregroundStyle(.blue)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.startedAt, style: .timer)
                        .font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Label("\(context.state.speedMilesPerHour) mph", systemImage: "speedometer")
                        Spacer()
                        Text(String(format: "%.1f mi", context.state.distanceMiles))
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text("\(context.state.eventCount) events")
                    }
                    .font(.subheadline.weight(.medium))
                }
            } compactLeading: {
                Image(systemName: "steeringwheel")
                    .foregroundStyle(.blue)
            } compactTrailing: {
                Text(context.attributes.startedAt, style: .timer)
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: "steeringwheel")
                    .foregroundStyle(.blue)
            }
            .keylineTint(.blue)
        }
    }
}
