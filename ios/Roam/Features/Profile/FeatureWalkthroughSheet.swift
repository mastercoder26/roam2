import SwiftUI

/// A compact, replayable guided tour. It is intentionally an on-demand sheet:
/// the app's launch experience stays fast, while the full product story is
/// always available from Settings.
struct FeatureWalkthroughSheet: View {
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentStep: FeatureWalkthroughStep = .plan

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                progressRail
                    .padding(.horizontal, AppDesign.space20)
                    .padding(.top, AppDesign.space12)

                Spacer(minLength: AppDesign.space24)

                featureStory
                    .padding(.horizontal, AppDesign.contentPadding)

                Spacer(minLength: AppDesign.space24)

                primaryAction
                    .padding(.horizontal, AppDesign.contentPadding)
                    .padding(.bottom, AppDesign.space20)
            }
            .background(AppCanvasBackground())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Skip") { dismiss() }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("walkthrough.skip")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var progressRail: some View {
        HStack(spacing: AppDesign.space8) {
            ForEach(FeatureWalkthroughStep.allCases) { step in
                Capsule(style: .continuous)
                    .fill(step == currentStep ? AppDesign.accent : AppDesign.trackSurface)
                    .frame(maxWidth: .infinity)
                    .frame(height: 5)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Guide progress, \(currentStep.progressLabel)")
        .accessibilityIdentifier("walkthrough.progress")
    }

    private var featureStory: some View {
        VStack(alignment: .leading, spacing: AppDesign.space20) {
            walkthroughIllustration

            VStack(alignment: .leading, spacing: AppDesign.space8) {
                Text(currentStep.progressLabel.uppercased())
                    .font(AppDesign.Typography.microLabel)
                    .tracking(1.1)
                    .foregroundStyle(AppDesign.accent)

                Text(currentStep.title)
                    .font(AppDesign.Typography.display)
                    .tracking(-0.9)
                    .foregroundStyle(AppDesign.Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(currentStep.detail)
                    .font(AppDesign.Typography.body)
                    .foregroundStyle(AppDesign.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .id(currentStep)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
        .animation(reduceMotion ? AppAnimation.quick : AppAnimation.content, value: currentStep)
        .accessibilityElement(children: .combine)
    }

    private var walkthroughIllustration: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppDesign.cornerRadiusHero, style: .continuous)
                .fill(AppDesign.cardSurfaceElevated)

            Circle()
                .fill(AppDesign.accent.opacity(0.14))
                .frame(width: 168, height: 168)
                .offset(x: 82, y: -48)
                .accessibilityHidden(true)

            Image(systemName: currentStep.symbol)
                .font(.system(size: 62, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(AppDesign.accent)
                .frame(width: 116, height: 116)
                .background(AppDesign.cardSurface, in: Circle())
                .overlay(Circle().stroke(AppDesign.cardStrokeStrong, lineWidth: 0.75))
                .elevation(AppDesign.Elevation.medium)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 245)
        .clipShape(RoundedRectangle(cornerRadius: AppDesign.cornerRadiusHero, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppDesign.cornerRadiusHero, style: .continuous)
                .stroke(AppDesign.cardStrokeStrong, lineWidth: 0.75)
        }
        .elevation(AppDesign.Elevation.hero)
    }

    private var primaryAction: some View {
        Button(action: advance) {
            HStack(spacing: AppDesign.space8) {
                Text(currentStep.actionTitle)
                Spacer(minLength: 0)
                Image(systemName: currentStep.next == nil ? "checkmark" : "arrow.right")
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(AppDesign.primarySurfaceForeground)
            .padding(.horizontal, AppDesign.space16)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(AppDesign.accent, in: RoundedRectangle(cornerRadius: AppDesign.cornerRadius, style: .continuous))
        }
        .buttonStyle(PressableScaleStyle())
        .accessibilityHint(currentStep.next == nil ? "Closes the Roam guide" : "Shows the next part of the Roam guide")
        .accessibilityIdentifier(currentStep.next == nil ? "walkthrough.finish" : "walkthrough.next")
    }

    private func advance() {
        guard let next = currentStep.next else {
            dismiss()
            return
        }
        withAnimation(reduceMotion ? AppAnimation.quick : AppAnimation.content) {
            currentStep = next
        }
    }
}

#Preview {
    FeatureWalkthroughSheet()
}
