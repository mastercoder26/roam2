import Foundation

/// A record of the most recent `/api/route/difficulty` attempt for one drive,
/// kept only in memory for on-screen troubleshooting. Never persisted or
/// synced — it exists so a driver stuck on "Analyzing route difficulty" can
/// see what the request actually did instead of guessing.
struct RouteAnalysisDebugInfo: Equatable {
    enum Outcome: Equatable {
        case success
        case httpError(statusCode: Int, message: String?)
        case unauthorized(String)
        case networkError(String)
        case decodingError(String)
        case other(String)

        var summary: String {
            switch self {
            case .success:
                return "200 OK"
            case let .httpError(statusCode, message):
                return "HTTP \(statusCode)" + (message.map { ": \($0)" } ?? "")
            case let .unauthorized(message):
                return "Unauthorized: \(message)"
            case let .networkError(message):
                return "Network error: \(message)"
            case let .decodingError(message):
                return "Decode error: \(message)"
            case let .other(message):
                return message
            }
        }
    }

    let endpointPath: String
    let attemptedAt: Date
    let durationSeconds: TimeInterval
    let retryCount: Int
    let outcome: Outcome

    /// A single line suitable for a debug caption: what was called, when,
    /// how long it took, and what happened.
    var debugSummary: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let time = formatter.string(from: attemptedAt)
        let duration = String(format: "%.1fs", durationSeconds)
        return "\(endpointPath) · attempt \(retryCount) · \(time) · \(duration) · \(outcome.summary)"
    }

    static func outcome(for error: Error) -> Outcome {
        switch error {
        case let apiError as APIError:
            switch apiError {
            case let .httpError(statusCode, message):
                return .httpError(statusCode: statusCode, message: message)
            case .networkError(let underlying):
                return .networkError(underlying.localizedDescription)
            case .decodingError(let underlying):
                return .decodingError(underlying.localizedDescription)
            case .invalidURL, .invalidResponse:
                return .other(apiError.localizedDescription ?? "Invalid response")
            }
        case let authError as AuthError:
            return .unauthorized(authError.errorDescription ?? "Not signed in")
        default:
            return .other(error.localizedDescription)
        }
    }
}
