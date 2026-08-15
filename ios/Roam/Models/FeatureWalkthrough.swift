import Foundation

/// The fixed product story shown from Settings. Keeping its order and copy
/// outside SwiftUI makes the walkthrough straightforward to verify and keeps
/// the visual layer focused on presentation.
enum FeatureWalkthroughStep: String, CaseIterable, Identifiable {
    case plan
    case understand
    case drive
    case grow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plan: "Plan with context"
        case .understand: "Understand the road ahead"
        case .drive: "Keep a quiet record"
        case .grow: "Build confidence over time"
        }
    }

    var detail: String {
        switch self {
        case .plan:
            "Routes starts with where you are going, then compares options before you leave."
        case .understand:
            "See what may make each route demanding, from turns and traffic to conditions."
        case .drive:
            "Drive records when you choose, while keeping the live view focused on the road."
        case .grow:
            "Progress turns completed drives into useful patterns and practice ideas. Profile keeps your settings and milestones close."
        }
    }

    var symbol: String {
        switch self {
        case .plan: "point.topleft.down.curvedto.point.bottomright.up"
        case .understand: "road.lanes"
        case .drive: "steeringwheel"
        case .grow: "chart.line.uptrend.xyaxis"
        }
    }

    var actionTitle: String {
        self == .grow ? "Start exploring" : "Continue"
    }

    var progressLabel: String {
        guard let index = Self.allCases.firstIndex(of: self) else { return "" }
        return "\(index + 1) of \(Self.allCases.count)"
    }

    var next: FeatureWalkthroughStep? {
        guard let index = Self.allCases.firstIndex(of: self), index < Self.allCases.count - 1 else {
            return nil
        }
        return Self.allCases[index + 1]
    }

    static func step(at index: Int) -> FeatureWalkthroughStep {
        let safeIndex = min(max(index, 0), allCases.count - 1)
        return allCases[safeIndex]
    }
}
