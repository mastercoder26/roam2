import Combine
import Foundation

/// Coordinates the app-side half of a route shared from the system share
/// sheet. It never calls the scoring backend. Its only job is to turn a saved
/// local handoff into an editable route form when Roam is active.
@MainActor
final class SharedRouteImportCoordinator: ObservableObject {
    enum State: Equatable {
        case idle
        case resolvingGoogleMapsLink
        case ready(SharedRouteDraft)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let inbox: SharedRouteInbox
    private let shortLinkResolver: any GoogleMapsShortLinkResolving
    private var isRefreshing = false

    init(
        inbox: SharedRouteInbox = SharedRouteInbox(),
        shortLinkResolver: any GoogleMapsShortLinkResolving = GoogleMapsShortLinkResolver()
    ) {
        self.inbox = inbox
        self.shortLinkResolver = shortLinkResolver
    }

    func refresh() async {
        guard !isRefreshing else { return }
        if case .ready = state { return }

        guard let item = inbox.peek() else {
            // A shared route that this build cannot decode is kept, not
            // deleted. Say so rather than showing an empty Home screen that
            // looks like the share never happened.
            state = inbox.hasUnreadableEntries ? .failed(Self.unreadableInboxMessage) : .idle
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        switch item {
        case let .route(route):
            state = .ready(route)

        case let .unresolvedGoogleShortLink(link):
            state = .resolvingGoogleMapsLink
            do {
                let finalURL = try await shortLinkResolver.resolve(link.url)
                // Failing to read the resolved page is not the same as the
                // page being unsupported: a consent interstitial resolves
                // differently on the next attempt. Keep it retriable.
                guard case let .ready(candidate) = SharedRouteImportParser.parse(url: finalURL, text: nil) else {
                    throw GoogleMapsShortLinkResolverError.unreadableRedirectTarget
                }
                let route = SharedRouteDraft(
                    id: link.id,
                    provider: candidate.provider,
                    origin: candidate.origin,
                    destination: candidate.destination,
                    importedAt: link.receivedAt,
                    waypointCount: candidate.waypointCount
                )
                guard inbox.replaceGoogleShortLink(id: link.id, with: route) else {
                    throw GoogleMapsShortLinkResolverError.invalidLink
                }
                state = .ready(route)
            } catch {
                if Self.isPermanentResolutionFailure(error) {
                    inbox.acknowledge(id: link.id)
                    state = .failed(error.localizedDescription)
                } else {
                    state = .failed(Self.retryableFailureMessage)
                }
            }
        }
    }

    func acknowledgeReadyRoute(id: UUID) {
        guard case let .ready(route) = state, route.id == id else { return }
        inbox.acknowledge(id: id)
        state = .idle
    }

    func dismissFailure() {
        guard case .failed = state else { return }
        state = .idle
    }

    static let retryableFailureMessage = "Roam could not finish reading this Google Maps link right now. The route is saved and will be tried again when Roam is next active."

    static let unreadableInboxMessage = "A route shared with Roam could not be opened in this version. It is still saved on the device and is not being deleted."

    /// Only a failure that cannot change on a retry may consume the saved
    /// share. Anything else — a network error, an interstitial, a page Roam
    /// could not read this time — keeps the link so the retry Roam promises
    /// actually happens.
    nonisolated static func isPermanentResolutionFailure(_ error: Error) -> Bool {
        guard let resolverError = error as? GoogleMapsShortLinkResolverError else {
            return false
        }
        return resolverError.isPermanent
    }
}
