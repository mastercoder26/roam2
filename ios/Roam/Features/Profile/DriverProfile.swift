import Combine
import Foundation

/// The small, stable information architecture for the Profile tab. Keeping
/// this separate from SwiftUI makes the order and user-facing copy testable.
enum ProfileFolder: String, CaseIterable, Identifiable {
    case progress
    case drivingInsights
    case preferences

    var id: String { rawValue }

    var title: String {
        switch self {
        case .progress: "Goals & progress"
        case .drivingInsights: "Driving insights"
        case .preferences: "Preferences"
        }
    }

    var subtitle: String {
        switch self {
        case .progress: "Milestones and your licensing stage"
        case .drivingInsights: "Experience, behavior, and weekly trends"
        case .preferences: "Color scheme and app icon"
        }
    }

    var summary: String { subtitle }

    var symbol: String {
        switch self {
        case .progress: "flag.checkered"
        case .drivingInsights: "chart.xyaxis.line"
        case .preferences: "slider.horizontal.3"
        }
    }
}

/// The top-level groups on Profile home. Account actions deliberately do not
/// share a card with progress or appearance settings: they have different
/// consequences and need their own visual boundary.
enum ProfileHomeSection: String, CaseIterable, Identifiable {
    case explore
    case appearance
    case account

    var id: String { rawValue }

    var title: String {
        switch self {
        case .explore: "Explore your profile"
        case .appearance: "Appearance"
        case .account: "Account"
        }
    }

    var folders: [ProfileFolder] {
        switch self {
        case .explore: [.progress, .drivingInsights]
        case .appearance: [.preferences]
        case .account: []
        }
    }
}

/// The driver's self-declared identity. Deliberately separate from anything
/// measured: nothing here feeds a route score, a drive score, or readiness.
/// It exists so the app can address the person by name and frame their own
/// progress against the stage they say they are at.
struct DriverProfile: Equatable, Codable {
    enum Stage: String, CaseIterable, Identifiable, Codable {
        case permit
        case provisional
        case licensed

        var id: String { rawValue }

        var title: String {
            switch self {
            case .permit: "Learner's permit"
            case .provisional: "Provisional license"
            case .licensed: "Full license"
            }
        }

        var detail: String {
            switch self {
            case .permit: "Practicing with a supervising driver."
            case .provisional: "Driving alone with restrictions still in place."
            case .licensed: "Unrestricted, still building experience."
            }
        }

        /// A short, factual note the UI can surface alongside the stage.
        /// Deliberately general, not tied to any specific jurisdiction's
        /// rules, and not a claim of legal compliance: it is a nudge, not a
        /// guarantee. Kept separate from `detail`, which describes the
        /// stage itself rather than suggesting anything to do about it.
        var supervisionNote: String {
            switch self {
            case .permit: "Many places require a supervising driver in the car at all times."
            case .provisional: "Curfews and passenger limits are common at this stage, check local rules."
            case .licensed: "Most restrictions typically lift here, but confirm what applies locally."
            }
        }
    }

    var displayName: String
    var stage: Stage

    static let empty = DriverProfile(displayName: "", stage: .permit)
}

/// Persists the profile locally. `UserDefaults` is correct here precisely
/// because none of this is sensitive or authoritative, it is a display
/// preference, not a credential and not a measurement.
@MainActor
final class DriverProfileStore: ObservableObject {
    static let shared = DriverProfileStore()

    /// Declared once. `load` and `persist` both read this instead of
    /// carrying their own copies of the literal, so the key cannot drift
    /// between the two call sites.
    static let storageKey = "roam.driver-profile-v1"
    private static let updateDateKey = "roam.driver-profile-updated-at-v1"

    /// Names longer than this are truncated, not rejected, so a driver who
    /// pastes something long still ends up with a usable, storable value.
    private static let maxNameLength = 80

    private let defaults: UserDefaults
    private var isApplyingRemoteUpdate = false

    private(set) var lastUpdatedAt: Date

    @Published var displayName: String {
        didSet {
            // Only the keystroke-safe rules run here. Collapsing whitespace
            // on every mutation would delete the space the moment it is
            // typed, since the bound TextField writes back the sanitized
            // value, making a two word name impossible to enter.
            let sanitized = Self.sanitizeWhileEditing(displayName)
            guard sanitized == displayName else {
                // Re-entrant assignment: this fires didSet again with the
                // sanitized value, which then falls through to persist().
                displayName = sanitized
                return
            }
            persist()
        }
    }

    /// Applies the rules that are only safe once the driver has finished
    /// typing: collapsing interior whitespace runs and trimming the ends.
    /// The UI calls this when editing is committed.
    func commitDisplayNameEdit() {
        let finalized = Self.sanitizeName(displayName)
        guard finalized != displayName else { return }
        displayName = finalized
    }

    @Published var stage: DriverProfile.Stage {
        didSet {
            persist()
        }
    }

    /// Set whenever the most recent write to `UserDefaults` failed. This is
    /// a local display preference, not critical data, so a failed write
    /// must never crash the app or trigger a network report. It is instead
    /// surfaced here so the UI can choose to show a small, honest
    /// "couldn't save" indicator rather than the failure being swallowed
    /// silently.
    @Published private(set) var lastPersistenceError: String?

    /// Falls back to a neutral label rather than an empty headline, so the
    /// card never renders as a blank row before the driver enters a name.
    var resolvedDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Your profile" : trimmed
    }

    /// Initials for the avatar. Returns an empty string when no name has
    /// been entered, deliberately, rather than a placeholder glyph like an
    /// em dash: em dashes are banned project-wide, and baking in any other
    /// arbitrary character here would just move the same problem one layer
    /// down. An empty monogram lets the UI decide how to render an empty
    /// avatar, for example with a system icon, without this layer guessing.
    var monogram: String {
        let initials = displayName
            .split(whereSeparator: \.isWhitespace)
            .compactMap(\.first)
            .prefix(2)
        guard !initials.isEmpty else { return "" }
        return String(initials).uppercased()
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = Self.load(from: defaults) ?? .empty
        displayName = stored.displayName
        stage = stored.stage
        lastUpdatedAt = defaults.object(forKey: Self.updateDateKey) as? Date ?? .distantPast
    }

    var snapshot: DriverProfile {
        DriverProfile(displayName: displayName, stage: stage)
    }

    /// Applies the server's winning profile without making it look like a new
    /// local edit. The server timestamp remains the conflict baseline for the
    /// next offline edit.
    func applyRemoteProfile(displayName: String, stage: DriverProfile.Stage, updatedAt: Date) {
        isApplyingRemoteUpdate = true
        self.displayName = displayName
        self.stage = stage
        commitDisplayNameEdit()
        isApplyingRemoteUpdate = false
        lastUpdatedAt = updatedAt
        defaults.set(updatedAt, forKey: Self.updateDateKey)
    }

    /// Account deletion clears only the local profile preference. Recorded
    /// drives and other local app features remain available in guest mode.
    func reset() {
        isApplyingRemoteUpdate = true
        displayName = DriverProfile.empty.displayName
        stage = DriverProfile.empty.stage
        isApplyingRemoteUpdate = false
        defaults.removeObject(forKey: Self.storageKey)
        defaults.removeObject(forKey: Self.updateDateKey)
        lastUpdatedAt = .distantPast
        lastPersistenceError = nil
    }

    private static func load(from defaults: UserDefaults) -> DriverProfile? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(DriverProfile.self, from: data)
    }

    private func persist() {
        let profile = DriverProfile(displayName: displayName, stage: stage)
        do {
            let data = try JSONEncoder().encode(profile)
            defaults.set(data, forKey: Self.storageKey)
            if !isApplyingRemoteUpdate {
                lastUpdatedAt = Date()
                defaults.set(lastUpdatedAt, forKey: Self.updateDateKey)
            }
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = error.localizedDescription
        }
    }

    /// Strips newlines and other control characters, collapses runs of
    /// whitespace to a single space, trims the ends, and caps the length.
    /// Deliberately scalar-based rather than regex-based so combining
    /// marks in non-Latin scripts (accents, diacritics) survive intact,
    /// and deliberately permissive of apostrophes and hyphens since those
    /// are legitimate parts of real names.
    private static func sanitizeName(_ raw: String) -> String {
        // The length cap is applied before the collapse so the function is a
        // true fixed point. Capping afterwards could reintroduce a trailing
        // space by truncating mid-gap, leaving a value that is not equal to
        // its own sanitization and forcing another didSet pass.
        let collapsed = sanitizeWhileEditing(raw)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")

        return collapsed
    }

    /// The subset of sanitization that is safe to apply on every keystroke.
    /// It strips characters that must never be stored, and caps the length,
    /// but leaves spacing alone so the driver can actually type a space
    /// between a first and last name.
    private static func sanitizeWhileEditing(_ raw: String) -> String {
        var normalized: [Unicode.Scalar] = []
        normalized.reserveCapacity(raw.unicodeScalars.count)

        for scalar in raw.unicodeScalars {
            if CharacterSet.newlines.contains(scalar) || scalar == "\t" {
                normalized.append(" ")
            } else if scalar.properties.generalCategory == .control {
                // Deliberately Cc only. Foundation's controlCharacters set is
                // Cc plus Cf, and Cf includes the zero width joiner and non
                // joiner that Persian and Devanagari names depend on, so
                // using it here silently rewrote real names into other words.
                continue
            } else {
                normalized.append(scalar)
            }
        }

        return String(String(String.UnicodeScalarView(normalized)).prefix(maxNameLength))
    }
}
