import Foundation

@main
struct SharedRouteImportChecks {
    static func main() async {
        appleDrivingDirectionsDecodeBothEndpoints()
        destinationOnlyAppleLinkUsesCurrentLocation()
        googleDirectionsDecodeRouteAndWaypoints()
        googlePathDirectionsKeepTheFinalDestination()
        googleShortLinksRequireResolution()
        nonDrivingLinksAreRejected()
        textFallbackFindsAMapLink()
        untrustedLinksAreRejected()
        lookalikeGoogleHostsAreRejected()
        genericGoogleShortLinksAreRejected()
        inboxIsFIFOAndAcknowledgesPrecisely()
        staleAcknowledgementDoesNotDropANewerRoute()
        expiredSharesArePhysicallyPurged()
        formReducerPreservesUserControl()
        unreadableInboxIsQuarantinedInsteadOfDeleted()
        onlyUnchangeableFailuresAreTreatedAsPermanent()
        await googleShortLinkResolutionStaysOutsideTheScoringBackend()
        await transientGoogleShortLinkFailureKeepsTheRoute()
        await anUnreadableRedirectTargetKeepsTheLinkForRetry()
        await anUnsupportedRedirectConsumesTheLink()
        await anUnreadableInboxIsReportedInsteadOfShowingNothing()

        print("Shared route import checks passed")
    }

    private static func appleDrivingDirectionsDecodeBothEndpoints() {
        let url = URL(string: "https://maps.apple.com/?saddr=1+Infinite+Loop%2C+Cupertino%2C+CA&daddr=Apple+Park%2C+Cupertino%2C+CA&dirflg=d")!

        guard case let .ready(route) = SharedRouteImportParser.parse(url: url, text: nil) else {
            fail("an Apple Maps driving route should parse")
        }

        expect(route.provider == .appleMaps, "the Apple Maps provider should be retained")
        expect(route.origin == "1 Infinite Loop, Cupertino, CA", "the Apple Maps origin should decode plus signs")
        expect(route.destination == "Apple Park, Cupertino, CA", "the Apple Maps destination should decode")
        expect(route.travelMode == .driving, "the Apple Maps travel mode should be driving")
    }

    private static func destinationOnlyAppleLinkUsesCurrentLocation() {
        let url = URL(string: "https://maps.apple.com/?daddr=500+Congress+Ave%2C+Austin%2C+TX&dirflg=d")!

        guard case let .ready(route) = SharedRouteImportParser.parse(url: url, text: nil) else {
            fail("a destination-only Apple Maps route should parse")
        }

        expect(route.origin == nil, "a destination-only map link must not invent an origin")
        expect(route.destination == "500 Congress Ave, Austin, TX", "the destination should remain usable")
    }

    private static func googleDirectionsDecodeRouteAndWaypoints() {
        let url = URL(string: "https://www.google.com/maps/dir/?api=1&origin=Austin%2C+TX&destination=Dallas%2C+TX&waypoints=Waco%2C+TX%7CTemple%2C+TX&travelmode=driving")!

        guard case let .ready(route) = SharedRouteImportParser.parse(url: url, text: nil) else {
            fail("a canonical Google Maps route should parse")
        }

        expect(route.provider == .googleMaps, "the Google Maps provider should be retained")
        expect(route.origin == "Austin, TX", "the Google Maps origin should decode")
        expect(route.destination == "Dallas, TX", "the Google Maps destination should decode")
        expect(route.waypointCount == 2, "extra stops must be disclosed instead of silently claimed as preserved")
    }

    private static func googlePathDirectionsKeepTheFinalDestination() {
        let url = URL(string: "https://www.google.com/maps/dir/Austin%2C+TX/Waco%2C+TX/Dallas%2C+TX")!

        guard case let .ready(route) = SharedRouteImportParser.parse(url: url, text: nil) else {
            fail("a Google Maps path route should parse")
        }

        expect(route.origin == "Austin, TX", "a path route should retain its first endpoint as the origin")
        expect(route.destination == "Dallas, TX", "a path route must use its final endpoint as the destination")
        expect(route.waypointCount == 1, "middle path endpoints must be disclosed as additional stops")
    }

    private static func googleShortLinksRequireResolution() {
        let url = URL(string: "https://maps.app.goo.gl/abc123")!
        let result = SharedRouteImportParser.parse(url: url, text: nil)

        guard case let .needsGoogleShortLinkResolution(shortURL) = result else {
            fail("a Google Maps short link must ask for a constrained resolution step")
        }

        expect(shortURL == url, "the short URL should be preserved only until it is resolved")
    }

    private static func nonDrivingLinksAreRejected() {
        let url = URL(string: "https://www.google.com/maps/dir/?api=1&origin=Austin&destination=Dallas&travelmode=transit")!
        let result = SharedRouteImportParser.parse(url: url, text: nil)

        guard case let .unsupportedTravelMode(mode) = result else {
            fail("a transit link must not silently become a driving analysis")
        }

        expect(mode == .transit, "the unsupported travel mode should be explained accurately")
    }

    private static func textFallbackFindsAMapLink() {
        let text = "Try this route: https://maps.apple.com/?saddr=Austin&daddr=San+Antonio&dirflg=d"

        guard case let .ready(route) = SharedRouteImportParser.parse(url: nil, text: text) else {
            fail("a plain-text map link should be accepted when a host does not provide a URL attachment")
        }

        expect(route.origin == "Austin", "the text fallback should preserve the origin")
        expect(route.destination == "San Antonio", "the text fallback should preserve the destination")
    }

    private static func untrustedLinksAreRejected() {
        let url = URL(string: "https://example.com/?origin=Austin&destination=Dallas")!
        let result = SharedRouteImportParser.parse(url: url, text: nil)

        guard case .unsupported = result else {
            fail("an unrelated web link must not be treated as a route")
        }
    }

    private static func lookalikeGoogleHostsAreRejected() {
        let lookalikes = [
            "https://www.google.evil.example/maps/dir/?origin=Austin&destination=Dallas",
            "https://maps.google.attacker.tld/maps/dir/?origin=Austin&destination=Dallas"
        ]

        for value in lookalikes {
            guard let url = URL(string: value) else {
                fail("the test URL should be valid")
            }
            guard case .unsupported = SharedRouteImportParser.parse(url: url, text: nil) else {
                fail("lookalike Google hosts must not be trusted")
            }
        }
    }

    private static func genericGoogleShortLinksAreRejected() {
        let url = URL(string: "https://goo.gl/maps/abc123")!
        guard case .unsupported = SharedRouteImportParser.parse(url: url, text: nil) else {
            fail("generic goo.gl links must not become unrestricted redirect requests")
        }
    }

    private static func inboxIsFIFOAndAcknowledgesPrecisely() {
        let directory = temporaryInboxDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = SharedRouteDraft(
            id: UUID(),
            provider: .appleMaps,
            origin: "Austin, TX",
            destination: "Dallas, TX",
            importedAt: Date(timeIntervalSince1970: 100),
            waypointCount: 0
        )
        let second = SharedRouteDraft(
            id: UUID(),
            provider: .googleMaps,
            origin: nil,
            destination: "Houston, TX",
            importedAt: Date(timeIntervalSince1970: 101),
            waypointCount: 0
        )
        let inbox = SharedRouteInbox(storageDirectory: directory)

        inbox.enqueue(route: first, now: first.importedAt)
        inbox.enqueue(route: second, now: second.importedAt)

        expect(inbox.peek(now: Date(timeIntervalSince1970: 102))?.id == first.id, "the first shared route should be delivered first")
        inbox.acknowledge(id: second.id, now: Date(timeIntervalSince1970: 102))
        expect(inbox.peek(now: Date(timeIntervalSince1970: 102))?.id == first.id, "acknowledging a later route must not remove an earlier route")
        inbox.acknowledge(id: first.id, now: Date(timeIntervalSince1970: 102))
        expect(inbox.peek(now: Date(timeIntervalSince1970: 102)) == nil, "acknowledging the active route should remove it")
    }

    private static func staleAcknowledgementDoesNotDropANewerRoute() {
        let directory = temporaryInboxDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = SharedRouteDraft(
            id: UUID(),
            provider: .appleMaps,
            origin: "Austin, TX",
            destination: "Dallas, TX",
            importedAt: Date(timeIntervalSince1970: 100),
            waypointCount: 0
        )
        let second = SharedRouteDraft(
            id: UUID(),
            provider: .googleMaps,
            origin: "Dallas, TX",
            destination: "Houston, TX",
            importedAt: Date(timeIntervalSince1970: 101),
            waypointCount: 0
        )
        let reader = SharedRouteInbox(storageDirectory: directory)
        let writer = SharedRouteInbox(storageDirectory: directory)

        expect(reader.enqueue(route: first, now: first.importedAt), "the first route should be stored")
        expect(reader.peek(now: Date(timeIntervalSince1970: 102))?.id == first.id, "the reader should see the first route before the extension writes")
        expect(writer.enqueue(route: second, now: second.importedAt), "the extension-side writer should preserve its route")
        reader.acknowledge(id: first.id, now: Date(timeIntervalSince1970: 102))
        expect(reader.peek(now: Date(timeIntervalSince1970: 102))?.id == second.id, "acknowledging an earlier route must preserve a concurrently saved route")
    }

    private static func expiredSharesArePhysicallyPurged() {
        let directory = temporaryInboxDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let inbox = SharedRouteInbox(storageDirectory: directory)
        let sharedAt = Date(timeIntervalSince1970: 100)
        let shortURL = URL(string: "https://maps.app.goo.gl/abc123")!
        expect(
            inbox.enqueueGoogleShortLink(shortURL, now: sharedAt),
            "a temporary Google Maps URL should be saved before it expires"
        )

        expect(
            inbox.peek(now: sharedAt.addingTimeInterval(16 * 60)) == nil,
            "expired shared links should not be returned"
        )
        let remainingFiles = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        expect(remainingFiles.isEmpty, "expired shared links must be physically removed from the App Group inbox")
    }

    private static func formReducerPreservesUserControl() {
        let importedRoute = SharedRouteDraft(
            id: UUID(),
            provider: .googleMaps,
            origin: "Austin, TX",
            destination: "Dallas, TX",
            importedAt: Date(),
            waypointCount: 1
        )
        let currentLocationRoute = SharedRouteDraft(
            id: UUID(),
            provider: .appleMaps,
            origin: nil,
            destination: "Houston, TX",
            importedAt: Date(),
            waypointCount: 0
        )

        let manualState = RoutePlanningFormReducer.applying(
            importedRoute,
            to: RoutePlanningFormState(origin: "Old origin", destination: "Old destination", originMode: .currentLocation)
        )
        expect(manualState.originMode == .manual, "an explicit shared origin should use manual origin mode")
        expect(manualState.origin == "Austin, TX", "an imported manual origin should replace stale form text")
        expect(manualState.destination == "Dallas, TX", "an imported destination should fill the planning form")
        expect(manualState.importedRouteID == importedRoute.id, "an import should be applied only once by its stable ID")

        let currentState = RoutePlanningFormReducer.applying(currentLocationRoute, to: manualState)
        expect(currentState.originMode == .currentLocation, "a destination-only link should retain the normal current-location flow")
        expect(currentState.origin.isEmpty, "a destination-only link should not retain a stale manual origin")
        expect(currentState.destination == "Houston, TX", "a destination-only link should still fill its destination")
    }

    @MainActor
    private static func googleShortLinkResolutionStaysOutsideTheScoringBackend() async {
        let directory = temporaryInboxDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let shortURL = URL(string: "https://maps.app.goo.gl/abc123")!
        let inbox = SharedRouteInbox(storageDirectory: directory)
        expect(inbox.enqueueGoogleShortLink(shortURL, id: UUID()), "a Google short link should be queued locally")

        let resolvedURL = URL(string: "https://www.google.com/maps/dir/?api=1&origin=Austin&destination=Dallas&travelmode=driving")!
        let coordinator = SharedRouteImportCoordinator(
            inbox: inbox,
            shortLinkResolver: StubGoogleShortLinkResolver(url: resolvedURL)
        )
        await coordinator.refresh()

        guard case let .ready(route) = coordinator.state else {
            fail("a resolved Google short link should become a local editable route")
        }
        expect(route.origin == "Austin", "the resolver should preserve the parsed origin")
        expect(route.destination == "Dallas", "the resolver should preserve the parsed destination")
        expect(inbox.peek()?.id == route.id, "the resolved route should remain local until the form accepts it")

        coordinator.acknowledgeReadyRoute(id: route.id)
        expect(inbox.peek() == nil, "accepting the route should consume only the saved local handoff")
    }

    @MainActor
    private static func transientGoogleShortLinkFailureKeepsTheRoute() async {
        let directory = temporaryInboxDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let shortURL = URL(string: "https://maps.app.goo.gl/abc123")!
        let id = UUID()
        let inbox = SharedRouteInbox(storageDirectory: directory)
        expect(inbox.enqueueGoogleShortLink(shortURL, id: id), "a Google short link should be queued before a retry")

        let coordinator = SharedRouteImportCoordinator(
            inbox: inbox,
            shortLinkResolver: StubGoogleShortLinkResolver(error: URLError(.notConnectedToInternet))
        )
        await coordinator.refresh()

        guard case .failed = coordinator.state else {
            fail("a temporary resolution failure should be shown honestly")
        }
        expect(inbox.peek()?.id == id, "a temporary network failure must not discard the saved route")
    }

    /// A schema change must not destroy a saved share. This is the same class
    /// of bug as the drive-history loss, and it gets the same quarantine.
    private static func unreadableInboxIsQuarantinedInsteadOfDeleted() {
        let directory = temporaryInboxDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let storageURL = directory.appendingPathComponent("shared-route-inbox-v1.json", isDirectory: false)
        // A future build's entry: valid JSON, undecodable by this schema.
        let futureSchema = Data(#"[{"id":"not-a-uuid","somethingNew":true}]"#.utf8)
        try? futureSchema.write(to: storageURL, options: .atomic)

        let inbox = SharedRouteInbox(storageDirectory: directory)

        expect(inbox.peek() == nil, "an unreadable inbox has no route this build can present")
        expect(
            inbox.hasUnreadableEntries,
            "an unreadable inbox must be reportable, not silently indistinguishable from an empty one"
        )
        expect(
            (try? Data(contentsOf: storageURL)) == futureSchema,
            "reading an unreadable inbox must not overwrite or delete the shared route"
        )

        let quarantineURL = directory.appendingPathComponent(
            "shared-route-inbox-v1-quarantined.json",
            isDirectory: false
        )
        expect(
            (try? Data(contentsOf: quarantineURL)) == futureSchema,
            "the original bytes should be kept for a later build that can read them"
        )

        let route = SharedRouteDraft(
            id: UUID(),
            provider: .appleMaps,
            origin: "Austin, TX",
            destination: "Dallas, TX",
            importedAt: Date(),
            waypointCount: 0
        )
        expect(
            !inbox.enqueue(route: route),
            "a write must refuse to run over an inbox this build could not read"
        )
        expect(
            (try? Data(contentsOf: storageURL)) == futureSchema,
            "a refused write must leave the stored share exactly as it was"
        )
    }

    private static func onlyUnchangeableFailuresAreTreatedAsPermanent() {
        typealias ResolverError = GoogleMapsShortLinkResolverError

        expect(ResolverError.invalidLink.isPermanent, "a link that is not a Google short link cannot become one")
        expect(
            ResolverError.unsupportedRedirect.isPermanent,
            "a redirect that leaves the trusted Google allowlist is genuinely unsupported"
        )
        expect(ResolverError.responseTooLarge.isPermanent, "an oversized response is a property of the link")
        expect(
            !ResolverError.unreadableRedirectTarget.isPermanent,
            "a page Roam could not read this time — an interstitial — must stay retriable"
        )

        expect(
            SharedRouteImportCoordinator.isPermanentResolutionFailure(URLError(.timedOut)) == false,
            "a network failure is never a reason to delete the saved route"
        )
        expect(
            SharedRouteImportCoordinator.isPermanentResolutionFailure(ResolverError.unreadableRedirectTarget) == false,
            "an unreadable redirect target must not consume the share"
        )
        expect(
            SharedRouteImportCoordinator.isPermanentResolutionFailure(ResolverError.unsupportedRedirect),
            "an unsupported redirect is still permanent"
        )
    }

    @MainActor
    private static func anUnreadableRedirectTargetKeepsTheLinkForRetry() async {
        let directory = temporaryInboxDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let shortURL = URL(string: "https://maps.app.goo.gl/abc123")!
        let id = UUID()
        let inbox = SharedRouteInbox(storageDirectory: directory)
        expect(inbox.enqueueGoogleShortLink(shortURL, id: id), "a Google short link should be queued")

        // A consent interstitial: still Google, still HTTPS, not a route.
        let interstitial = URL(string: "https://www.google.com/maps/consent?continue=%2Fmaps")!
        let coordinator = SharedRouteImportCoordinator(
            inbox: inbox,
            shortLinkResolver: StubGoogleShortLinkResolver(url: interstitial)
        )
        await coordinator.refresh()

        guard case let .failed(message) = coordinator.state else {
            fail("an unreadable redirect target should be reported, not silently dropped")
        }
        expect(
            message == SharedRouteImportCoordinator.retryableFailureMessage,
            "the message should promise the retry that actually happens"
        )
        expect(
            inbox.peek()?.id == id,
            "a region-dependent interstitial must not delete the shared link"
        )
    }

    @MainActor
    private static func anUnsupportedRedirectConsumesTheLink() async {
        let directory = temporaryInboxDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let shortURL = URL(string: "https://maps.app.goo.gl/abc123")!
        let inbox = SharedRouteInbox(storageDirectory: directory)
        expect(inbox.enqueueGoogleShortLink(shortURL, id: UUID()), "a Google short link should be queued")

        let coordinator = SharedRouteImportCoordinator(
            inbox: inbox,
            shortLinkResolver: StubGoogleShortLinkResolver(
                error: GoogleMapsShortLinkResolverError.unsupportedRedirect
            )
        )
        await coordinator.refresh()

        guard case .failed = coordinator.state else {
            fail("a genuinely unsupported redirect should still be reported")
        }
        expect(
            inbox.peek() == nil,
            "a failure that cannot change on a retry should not be retried forever"
        )
    }

    @MainActor
    private static func anUnreadableInboxIsReportedInsteadOfShowingNothing() async {
        let directory = temporaryInboxDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let storageURL = directory.appendingPathComponent("shared-route-inbox-v1.json", isDirectory: false)
        try? Data(#"[{"id":"not-a-uuid"}]"#.utf8).write(to: storageURL, options: .atomic)

        let coordinator = SharedRouteImportCoordinator(
            inbox: SharedRouteInbox(storageDirectory: directory),
            shortLinkResolver: StubGoogleShortLinkResolver(url: URL(string: "https://maps.app.goo.gl/abc123")!)
        )
        await coordinator.refresh()

        guard case let .failed(message) = coordinator.state else {
            fail("a shared route this build cannot read should be explained, not hidden")
        }
        expect(
            message == SharedRouteImportCoordinator.unreadableInboxMessage,
            "the message should say the route is kept, not lost"
        )
    }

    private static func temporaryInboxDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedRouteImportChecks", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        fatalError("Shared route import check failed: \(message)")
    }
}

private struct StubGoogleShortLinkResolver: GoogleMapsShortLinkResolving {
    private let url: URL?
    private let error: Error?

    init(url: URL) {
        self.url = url
        error = nil
    }

    init(error: Error) {
        url = nil
        self.error = error
    }

    func resolve(_ url: URL) async throws -> URL {
        if let error {
            throw error
        }
        guard let url = self.url else {
            throw URLError(.badURL)
        }
        return url
    }
}
