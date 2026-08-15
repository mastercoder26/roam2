import SwiftUI

/// Separates route-input provenance from the route-demand score. It intentionally
/// avoids confidence percentages and score intervals until a versioned, held-out
/// validation artifact exists for a declared prediction target.
struct RouteEvidenceCard: View {
    @ObservedObject private var theme = ThemeManager.shared
    let evidence: ScoreEvidence?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: evidenceSymbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(evidenceColor)
                    .frame(width: 28, height: 28)
                    .background(evidenceColor.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Evidence coverage")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppDesign.Ink.primary)
                    Text(evidence?.level.title ?? "Coverage unavailable")
                        .font(.caption)
                        .foregroundStyle(evidenceColor)
                }

                Spacer(minLength: 8)

                if let evidence {
                    Text("\(Int((evidence.inputCoverage * 100).rounded()))%")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(AppDesign.Ink.primary)
                        .accessibilityLabel("\(Int((evidence.inputCoverage * 100).rounded())) percent of route inputs verified")
                }
            }

            if let evidence {
                ProgressView(value: evidence.inputCoverage)
                    .tint(evidenceColor)
                    .accessibilityHidden(true)

                Text("\(evidence.verifiedInputCount) of \(evidence.totalInputCount) route inputs verified.")
                    .font(.caption)
                    .foregroundStyle(AppDesign.Ink.secondary)

                if !evidence.missingSignals.isEmpty {
                    Text("Unavailable now: \(evidence.unavailableInputTitles).")
                        .font(.caption)
                        .foregroundStyle(AppDesign.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("This route came from an older analysis service that did not report which inputs were verified.")
                    .font(.caption)
                    .foregroundStyle(AppDesign.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Coverage describes available route inputs, not a prediction of safety or whether someone should drive.")
                .font(.caption2)
                .foregroundStyle(AppDesign.Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppDesign.cardSurface, in: RoundedRectangle(cornerRadius: AppDesign.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppDesign.cornerRadius, style: .continuous)
                .stroke(AppDesign.cardStroke, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var evidenceColor: Color {
        switch evidence?.level {
        case .wellSupported:
            AppDesign.positive
        case .partial:
            AppDesign.accent
        case .limited, .none:
            AppDesign.safety
        }
    }

    private var evidenceSymbol: String {
        switch evidence?.level {
        case .wellSupported:
            "checkmark.seal.fill"
        case .partial:
            "chart.bar.xaxis"
        case .limited, .none:
            "exclamationmark.circle.fill"
        }
    }
}

#Preview {
    RouteEvidenceCard(
        evidence: ScoreEvidence(
            schemaVersion: "evidence-v1",
            inputCoverage: 0.68,
            level: .partial,
            predictiveValidation: .notValidated,
            signalCoverage: [
                .routeGeometry: 1,
                .trafficTiming: 1,
                .speedLimits: 0.5,
                .weather: 0,
                .roadMetadata: 1,
                .turnControls: 0,
            ],
            verifiedSignals: [.routeGeometry, .trafficTiming, .speedLimits, .roadMetadata],
            missingSignals: [.weather, .turnControls]
        )
    )
    .padding()
    .background(AppDesign.canvas)
}
