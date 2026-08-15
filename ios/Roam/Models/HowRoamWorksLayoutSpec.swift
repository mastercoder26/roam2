import Foundation

/// Shared spacing rules for the explanation sheet. Keeping these values in a
/// testable model prevents its many sections from slowly developing different
/// row and edge spacing as content changes.
enum HowRoamWorksLayoutSpec {
    static let topPadding: Double = 20
    static let bottomPadding: Double = 48
    static let sectionSpacing: Double = 32
    static let titleContentSpacing: Double = 10
    static let rowVerticalPadding: Double = 11
    static let entryRowVerticalPadding: Double = 14
    static let maximumContentWidth: Double = 640
}
