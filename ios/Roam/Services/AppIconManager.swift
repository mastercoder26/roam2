import Combine
import Foundation
import UIKit

/// Stable identifiers for the icons `Info.plist` declares under
/// `CFBundleIcons`. `primary` has no entry there — it is whatever the asset
/// catalog's `AppIcon` set renders — so it is the only case that passes `nil`
/// to `setAlternateIconName`.
enum AppIconID: String, CaseIterable, Identifiable {
    case primary
    case wordmark = "Wordmark"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .primary: "Default"
        case .wordmark: "Wordmark"
        }
    }

    var subtitle: String {
        switch self {
        case .primary: "The steering-wheel mark"
        case .wordmark: "Full Roam logo on cream"
        }
    }

    /// Asset catalog image set used for the picker thumbnail. Distinct from
    /// the loose `CFBundleIconFiles` PNGs iOS actually swaps in — those live
    /// outside the asset catalog because alternate icons must be plain files.
    var previewAssetName: String {
        switch self {
        case .primary: "AppIconPrimaryPreview"
        case .wordmark: "AppIconWordmarkPreview"
        }
    }

    fileprivate var alternateIconName: String? {
        switch self {
        case .primary: nil
        case .wordmark: rawValue
        }
    }
}

@MainActor
final class AppIconManager: ObservableObject {
    static let shared = AppIconManager()

    @Published private(set) var currentID: AppIconID
    @Published private(set) var lastError: String?

    private let application: UIApplication

    init(application: UIApplication = .shared) {
        self.application = application
        let alternateName = application.alternateIconName
        currentID = AppIconID.allCases.first { $0.alternateIconName == alternateName } ?? .primary
    }

    var supportsAlternateIcons: Bool {
        application.supportsAlternateIcons
    }

    func select(_ id: AppIconID) {
        guard supportsAlternateIcons, currentID != id else { return }
        let previousID = currentID
        lastError = nil
        application.setAlternateIconName(id.alternateIconName) { [weak self] error in
            guard let self else { return }
            Task { @MainActor in
                if let error {
                    self.currentID = previousID
                    self.lastError = Self.userFacingErrorMessage(for: error)
                } else {
                    self.currentID = id
                }
            }
        }
    }

    private static func userFacingErrorMessage(for error: Error) -> String {
        let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty,
              !description.localizedCaseInsensitiveContains("missing error") else {
            return "Couldn’t change the app icon. Try again in a moment."
        }
        return description
    }
}
