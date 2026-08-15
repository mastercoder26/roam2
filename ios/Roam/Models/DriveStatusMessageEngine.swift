import Foundation

/// Derives the post-drive banner text. The banner is set once when a drive is
/// saved and then again when its route analysis resolves, so the two messages
/// live together here rather than being spelled out at each call site.
enum DriveStatusMessageEngine {
    /// Shown while the route request is in flight. `resolvedMessage` replaces
    /// only this text, so a more important banner — a background suspension
    /// warning, say — is never overwritten by an analysis result.
    static let analyzing = "Drive saved. Analyzing route difficulty."

    /// The banner for a route analysis that has finished. `nil` means the
    /// analysis is still running and the caller should leave the banner alone.
    static func resolvedMessage(for analysis: DriveRouteAnalysis) -> String? {
        switch analysis.status {
        case .pending:
            return nil
        case .available:
            guard let score = analysis.difficultyScore, let label = analysis.label else {
                return "Drive saved. Route difficulty analyzed."
            }
            return "Drive saved. Route difficulty \(String(format: "%.1f", score))/10 · \(label.rawValue)."
        case .unavailable:
            return "Drive saved. Route difficulty unavailable."
        }
    }
}
