import Foundation

@main
struct DriverProfileStoreChecks {
    @MainActor
    static func main() {
        checkRoundTripPersistence()
        checkEmptyNameFallbackHasNoEmDash()
        checkMonogramCorrectness()
        checkNameSanitization()
        checkStageBackwardCompatibility()

        print("DriverProfileStore checks passed")
    }

    // MARK: - Isolated UserDefaults

    /// A fresh, uniquely named suite per check so runs never touch the real
    /// user's defaults and never leak state between checks.
    private static func makeIsolatedDefaults(named suffix: String) -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "roam.driver-profile-store-checks.\(suffix).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("DriverProfileStore check failed: could not create isolated UserDefaults suite")
        }
        return (defaults, suiteName)
    }

    private static func teardown(_ suiteName: String) {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Round trip persistence

    @MainActor
    private static func checkRoundTripPersistence() {
        let (defaults, suiteName) = makeIsolatedDefaults(named: "round-trip")
        defer { teardown(suiteName) }

        let first = DriverProfileStore(defaults: defaults)
        first.displayName = "Jordan Rivera"
        first.stage = .provisional

        let second = DriverProfileStore(defaults: defaults)
        expect(second.displayName == "Jordan Rivera", "reloaded store should recover the persisted name")
        expect(second.stage == .provisional, "reloaded store should recover the persisted stage")
        expect(second.lastPersistenceError == nil, "a clean load should not report a persistence error")
    }

    // MARK: - Empty name fallback

    @MainActor
    private static func checkEmptyNameFallbackHasNoEmDash() {
        let (defaults, suiteName) = makeIsolatedDefaults(named: "empty-fallback")
        defer { teardown(suiteName) }

        let store = DriverProfileStore(defaults: defaults)
        store.displayName = ""
        expect(!store.monogram.contains("\u{2014}"), "empty-name monogram must not contain an em dash")
        expect(store.monogram.isEmpty, "empty-name monogram should be an empty string, not a placeholder glyph")
        expect(store.resolvedDisplayName == "Your profile", "empty display name should fall back to a neutral label")
        expect(!store.resolvedDisplayName.contains("\u{2014}"), "resolved display name must not contain an em dash")
    }

    // MARK: - Monogram correctness

    @MainActor
    private static func checkMonogramCorrectness() {
        let (defaults, suiteName) = makeIsolatedDefaults(named: "monogram")
        defer { teardown(suiteName) }

        let store = DriverProfileStore(defaults: defaults)

        store.displayName = "Madison"
        expect(store.monogram == "M", "a single name should produce a one-letter monogram")

        store.displayName = "Madison Lee"
        expect(store.monogram == "ML", "a two-word name should produce initials from both words")

        store.displayName = "  Madison    Lee  "
        expect(store.monogram == "ML", "extra whitespace between and around words must not break the monogram")

        store.displayName = "Madison\tLee\nCarter"
        expect(store.monogram == "ML", "tabs and newlines should be treated as word separators, capped at two initials")

        store.displayName = ""
        expect(store.monogram.isEmpty, "an empty name should produce an empty monogram")

        store.displayName = "陳 美玲"
        expect(store.monogram == "陳美", "a non-Latin name should produce initials without trapping")
    }

    // MARK: - Name sanitization

    @MainActor
    private static func checkNameSanitization() {
        let (defaults, suiteName) = makeIsolatedDefaults(named: "sanitization")
        defer { teardown(suiteName) }

        let store = DriverProfileStore(defaults: defaults)

        let longName = String(repeating: "A", count: 500)
        store.displayName = longName
        expect(store.displayName.count <= 80, "an overlong name must be capped to a sane maximum length")

        store.displayName = "Line1\nLine2\r\nLine3"
        expect(!store.displayName.contains("\n"), "newlines must be stripped from a stored name")
        expect(!store.displayName.contains("\r"), "carriage returns must be stripped from a stored name")

        store.displayName = "Bad\u{0007}Bell\u{0000}Null"
        expect(!store.displayName.contains("\u{0007}"), "control characters like BEL must be stripped")
        expect(!store.displayName.contains("\u{0000}"), "control characters like NUL must be stripped")

        store.displayName = "O'Brien-Smith"
        expect(store.displayName == "O'Brien-Smith", "apostrophes and hyphens are legitimate name characters and must survive sanitization")

        // Whitespace is deliberately left alone while typing, otherwise the
        // space between a first and last name is deleted the instant it is
        // typed and a two word name cannot be entered at all. Collapsing is
        // applied when the edit is committed.
        store.displayName = "José  María"
        expect(store.displayName == "José  María", "spacing must survive while the driver is still typing")
        store.commitDisplayNameEdit()
        expect(store.displayName == "José María", "diacritics must survive and runaway whitespace collapses on commit")

        store.displayName = "Jane "
        expect(store.displayName == "Jane ", "a trailing space must survive so the next word can be typed")
        store.commitDisplayNameEdit()
        expect(store.displayName == "Jane", "a trailing space is trimmed once the edit is committed")

        // Zero width joiners carry meaning in Persian and Devanagari names,
        // so they must not be treated as strippable control characters.
        let zwnjName = "\u{0645}\u{06CC}\u{200C}\u{0631}"
        store.displayName = zwnjName
        expect(store.displayName == zwnjName, "zero width non joiners must survive sanitization")
    }

    // MARK: - Stage backward compatibility

    @MainActor
    private static func checkStageBackwardCompatibility() {
        for stage in DriverProfile.Stage.allCases {
            let decoded = try? JSONDecoder().decode(DriverProfile.Stage.self, from: Data("\"\(stage.rawValue)\"".utf8))
            expect(decoded == stage, "stage '\(stage.rawValue)' must still decode from its existing raw value")
        }

        // A profile blob shaped like one saved by an older build of the app
        // must still decode cleanly, so existing users never lose data.
        let legacyJSON = """
        {"displayName":"Taylor","stage":"provisional"}
        """
        let legacyProfile = try? JSONDecoder().decode(DriverProfile.self, from: Data(legacyJSON.utf8))
        expect(legacyProfile?.displayName == "Taylor", "a legacy saved profile's name must still decode")
        expect(legacyProfile?.stage == .provisional, "a legacy saved profile's stage must still decode")
    }

    // MARK: - Assertion helper

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError("DriverProfileStore check failed: \(message)")
        }
    }
}
