import Combine
import Foundation
import SwiftUI
import UIKit

extension RGBA {
    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    /// MapKit renderers and annotation views are UIKit, so they need a UIColor
    /// rather than a SwiftUI Color. Without this the maps stayed system blue
    /// no matter which theme was active.
    var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    private let storageKey = "roam.theme-id-v1"
    /// Snapshot for nonisolated `AppDesign` token reads outside the main actor.
    nonisolated(unsafe) private static var cachedID: ThemeID = ThemeCatalog.default

    @Published private(set) var currentID: ThemeID {
        didSet {
            Self.cachedID = currentID
            UserDefaults.standard.set(currentID.rawValue, forKey: storageKey)
        }
    }

    var palette: ThemePalette {
        ThemeCatalog.palette(for: currentID)
    }

    /// Safe for `AppDesign` static accessors that may run off the main actor.
    nonisolated static var cachedPalette: ThemePalette {
        ThemeCatalog.palette(for: cachedID)
    }

    var preferredColorScheme: ColorScheme {
        palette.appearance == .light ? .light : .dark
    }

    init(defaults: UserDefaults = .standard) {
        let saved = defaults.string(forKey: storageKey)
        let resolved = ThemeCatalog.resolve(rawValue: saved)
        currentID = resolved
        Self.cachedID = resolved
    }

    func select(_ id: ThemeID) {
        guard currentID != id else { return }
        currentID = id
    }
}
