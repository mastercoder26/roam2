import SwiftUI
import UIKit

struct AppIconPickerSheet: View {
    @ObservedObject var iconManager: AppIconManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var usesAccessibilityText: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("App icon")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(AppDesign.Ink.primary)
                    Text("Pick the icon shown on your Home Screen.")
                        .font(.footnote)
                        .foregroundStyle(AppDesign.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !iconManager.supportsAlternateIcons {
                        Label("This device can't switch app icons.", systemImage: "exclamationmark.circle")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AppDesign.safety)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppDesign.safety.opacity(0.12), in: RoundedRectangle(cornerRadius: AppDesign.cornerRadiusSmall, style: .continuous))
                    } else if let error = iconManager.lastError {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AppDesign.danger)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppDesign.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: AppDesign.cornerRadiusSmall, style: .continuous))
                    }

                    ForEach(AppIconID.allCases) { iconID in
                        iconRow(iconID)
                    }
                }
                .padding(20)
            }
            .background(AppDesign.canvas.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func iconRow(_ iconID: AppIconID) -> some View {
        let isSelected = iconManager.currentID == iconID
        let canSelect = iconManager.supportsAlternateIcons

        return Button {
            guard canSelect else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            iconManager.select(iconID)
        } label: {
            iconRowContent(iconID, isSelected: isSelected)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: AppDesign.cornerRadius, style: .continuous)
                        .fill(AppDesign.cardSurface)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: AppDesign.cornerRadius, style: .continuous)
                        .stroke(
                            isSelected ? AppDesign.accent.opacity(0.45) : AppDesign.cardStroke,
                            lineWidth: isSelected ? 1.5 : 1
                        )
                }
                .opacity(canSelect || isSelected ? 1 : 0.55)
        }
        .buttonStyle(PressableScaleStyle())
        .disabled(!canSelect)
        .accessibilityLabel(iconID.title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint(canSelect ? iconID.subtitle : "Unavailable on this device")
    }

    @ViewBuilder
    private func iconRowContent(_ iconID: AppIconID, isSelected: Bool) -> some View {
        if usesAccessibilityText {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 14) {
                    iconThumbnail(iconID)
                    iconCopy(iconID)
                }

                Label(
                    isSelected ? "Selected" : "Select this icon",
                    systemImage: isSelected ? "checkmark.circle.fill" : "circle"
                )
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isSelected ? AppDesign.accent : AppDesign.Ink.secondary)
            }
        } else {
            HStack(spacing: 14) {
                iconThumbnail(iconID)
                iconCopy(iconID)
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AppDesign.accent : AppDesign.Ink.tertiary)
            }
        }
    }

    private func iconCopy(_ iconID: AppIconID) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(iconID.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppDesign.Ink.primary)
            Text(iconID.subtitle)
                .font(.caption)
                .foregroundStyle(AppDesign.Ink.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func iconThumbnail(_ iconID: AppIconID) -> some View {
        Image(iconID.previewAssetName)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: AppDesign.cornerRadiusTiny, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppDesign.cornerRadiusTiny, style: .continuous)
                    .stroke(AppDesign.cardStrokeStrong, lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}

#Preview {
    AppIconPickerSheet(iconManager: AppIconManager.shared)
}
