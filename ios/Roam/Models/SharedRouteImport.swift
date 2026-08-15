import Foundation

/// The mapping provider that supplied a route. This is retained only for a
/// small import notice and is never sent to the route-scoring backend.
enum SharedRouteProvider: String, Codable, Equatable {
    case appleMaps
    case googleMaps

    var displayName: String {
        switch self {
        case .appleMaps:
            "Apple Maps"
        case .googleMaps:
            "Google Maps"
        }
    }
}

enum SharedRouteTravelMode: String, Codable, Equatable {
    case driving
    case walking
    case transit
    case bicycling
    case unknown
}

/// A parsed route before it enters the app-group inbox. It has no raw source
/// URL, so directly imported routes retain only the endpoints needed to fill
/// Roam's route form.
struct SharedRouteCandidate: Equatable {
    let provider: SharedRouteProvider
    let origin: String?
    let destination: String
    let travelMode: SharedRouteTravelMode
    let waypointCount: Int
}

enum SharedRouteImportParseResult: Equatable {
    case ready(SharedRouteCandidate)
    case needsGoogleShortLinkResolution(URL)
    case unsupportedTravelMode(SharedRouteTravelMode)
    case unsupported(String)
}

/// The privacy-safe representation moved from the Share extension to Roam.
/// A direct import stores endpoints only. A raw short URL exists only in the
/// short-lived inbox entry that still needs a redirect resolution.
struct SharedRouteDraft: Codable, Equatable, Identifiable {
    let id: UUID
    let provider: SharedRouteProvider
    let origin: String?
    let destination: String
    let importedAt: Date
    let waypointCount: Int
}

enum SharedRouteImportParser {
    static let maximumURLLength = 8_192
    static let maximumEndpointLength = 512

    static func parse(url: URL?, text: String?) -> SharedRouteImportParseResult {
        if let url {
            return parse(url: url)
        }

        let candidates = urls(in: text ?? "")
        guard !candidates.isEmpty else {
            return .unsupported("Roam could not find a map link in this share.")
        }

        let results = candidates.map { parse(url: $0) }
        if let complete = results.first(where: { result in
            guard case let .ready(route) = result else { return false }
            return route.origin != nil
        }) {
            return complete
        }
        if let destinationOnly = results.first(where: { result in
            guard case .ready = result else { return false }
            return true
        }) {
            return destinationOnly
        }
        if let shortLink = results.first(where: { result in
            guard case .needsGoogleShortLinkResolution = result else { return false }
            return true
        }) {
            return shortLink
        }
        if let mode = results.first(where: { result in
            guard case .unsupportedTravelMode = result else { return false }
            return true
        }) {
            return mode
        }
        return results.first ?? .unsupported("Roam could not read that map link.")
    }

    static func parse(url: URL) -> SharedRouteImportParseResult {
        guard isSafeLength(url), url.user == nil, url.password == nil else {
            return .unsupported("That map link is not valid.")
        }

        let scheme = url.scheme?.lowercased()
        let host = url.host?.lowercased()

        if scheme == "comgooglemaps" {
            return parseGoogle(url: url)
        }

        guard scheme == "https" || scheme == "http" else {
            return .unsupported("Roam only accepts shared Apple Maps or Google Maps links.")
        }

        if host == "maps.apple.com" {
            return parseApple(url: url)
        }
        if isGoogleShortLink(url) {
            return .needsGoogleShortLinkResolution(url)
        }
        if isGoogleMapsURL(url) {
            return parseGoogle(url: url)
        }
        return .unsupported("This link is not from Apple Maps or Google Maps.")
    }

    private static func parseApple(url: URL) -> SharedRouteImportParseResult {
        guard case let .success(query) = queryValues(in: url) else {
            return .unsupported("The Apple Maps link has invalid query values.")
        }
        guard !hasConflictingValues(named: ["saddr", "source", "daddr", "destination", "address", "q", "query"], in: query) else {
            return .unsupported("The Apple Maps link contains conflicting route details.")
        }
        let origin = singleEndpoint(named: ["saddr", "source"], in: query)
        guard let destination = singleEndpoint(named: ["daddr", "destination", "address", "q", "query"], in: query)
            ?? coordinateEndpoint(from: query) else {
            return .unsupported("Roam could not find a destination in this Apple Maps link.")
        }

        let mode = travelMode(from: singleValue(named: ["dirflg"], in: query))
        guard mode == .driving || mode == .unknown else {
            return .unsupportedTravelMode(mode)
        }

        return .ready(
            SharedRouteCandidate(
                provider: .appleMaps,
                origin: origin,
                destination: destination,
                travelMode: mode,
                waypointCount: 0
            )
        )
    }

    private static func parseGoogle(url: URL) -> SharedRouteImportParseResult {
        guard case let .success(query) = queryValues(in: url) else {
            return .unsupported("The Google Maps link has invalid query values.")
        }
        guard !hasConflictingValues(named: ["origin", "saddr", "destination", "daddr", "query", "q"], in: query) else {
            return .unsupported("The Google Maps link contains conflicting route details.")
        }

        let mode = travelMode(from: singleValue(named: ["travelmode", "directionsmode", "dirflg"], in: query))
        guard mode == .driving || mode == .unknown else {
            return .unsupportedTravelMode(mode)
        }

        let queryOrigin = singleEndpoint(named: ["origin", "saddr"], in: query)
        let queryDestination = singleEndpoint(named: ["destination", "daddr", "query", "q"], in: query)
        let pathRoute = routeFromGooglePath(url)

        let origin = queryOrigin ?? pathRoute?.origin
        guard let destination = queryDestination ?? pathRoute?.destination else {
            return .unsupported("Roam could not find a destination in this Google Maps link.")
        }

        let waypointCount = max(
            waypointCount(from: singleValue(named: ["waypoints"], in: query)),
            pathRoute?.waypointCount ?? 0
        )
        return .ready(
            SharedRouteCandidate(
                provider: .googleMaps,
                origin: origin,
                destination: destination,
                travelMode: mode,
                waypointCount: waypointCount
            )
        )
    }

    /// A nil result means either no endpoint was supplied or conflicting
    /// duplicates were supplied. The latter is deliberately rejected by the
    /// caller when it leaves the route without a usable destination.
    private static func singleEndpoint(
        named names: [String],
        in query: [String: [String]]
    ) -> String? {
        guard let raw = singleValue(named: names, in: query) else { return nil }
        return cleanEndpoint(raw)
    }

    private static func singleValue(
        named names: [String],
        in query: [String: [String]]
    ) -> String? {
        for name in names {
            let values = (query[name] ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !values.isEmpty else { continue }
            guard let first = values.first,
                  values.allSatisfy({ $0 == first }) else {
                return nil
            }
            return first
        }
        return nil
    }

    private static func hasConflictingValues(
        named names: [String],
        in query: [String: [String]]
    ) -> Bool {
        names.contains { name in
            let values = (query[name] ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return Set(values).count > 1
        }
    }

    private static func coordinateEndpoint(from query: [String: [String]]) -> String? {
        guard let raw = singleValue(named: ["ll"], in: query) else { return nil }
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let latitude = Double(parts[0]),
              let longitude = Double(parts[1]),
              (-90...90).contains(latitude),
              (-180...180).contains(longitude) else {
            return nil
        }
        return "\(latitude),\(longitude)"
    }

    private static func routeFromGooglePath(_ url: URL) -> (origin: String?, destination: String, waypointCount: Int)? {
        let path = url.path.split(separator: "/", omittingEmptySubsequences: false)
        guard let directoryIndex = path.firstIndex(where: { $0.lowercased() == "dir" }) else {
            return nil
        }

        let endpointParts = path.dropFirst(directoryIndex + 1)
            .prefix {
                let component = $0.lowercased()
                return !component.hasPrefix("data=") && !component.hasPrefix("@")
            }
            .map(String.init)
        guard !endpointParts.isEmpty else { return nil }

        let decoded = endpointParts.map { component -> String? in
            let formDecoded = component.replacingOccurrences(of: "+", with: " ")
            return formDecoded.removingPercentEncoding
        }
        guard !decoded.contains(where: { $0 == nil }) else {
            return nil
        }
        let endpoints = decoded.compactMap { $0 }.compactMap(cleanEndpoint)
        guard let destination = endpoints.last else { return nil }

        if endpoints.count >= 2 {
            return (
                origin: endpoints.first,
                destination: destination,
                waypointCount: max(0, endpoints.count - 2)
            )
        }
        return (origin: nil, destination: destination, waypointCount: 0)
    }

    private enum QueryValuesError: Error {
        case malformed
    }

    private static func queryValues(in url: URL) -> Result<[String: [String]], QueryValuesError> {
        guard let rawQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
              !rawQuery.isEmpty else {
            return .success([:])
        }

        var values: [String: [String]] = [:]
        for pair in rawQuery.split(separator: "&", omittingEmptySubsequences: false) {
            let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawName = pieces.first,
                  let name = decodeFormComponent(String(rawName)),
                  !name.isEmpty else {
                return .failure(.malformed)
            }
            let rawValue = pieces.count == 2 ? String(pieces[1]) : ""
            guard let value = decodeFormComponent(rawValue) else {
                return .failure(.malformed)
            }
            values[name.lowercased(), default: []].append(value)
        }
        return .success(values)
    }

    private static func decodeFormComponent(_ string: String) -> String? {
        string
            .replacingOccurrences(of: "+", with: " ")
            .removingPercentEncoding
    }

    private static func cleanEndpoint(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.count <= maximumEndpointLength,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        let lowercased = value.lowercased()
        if lowercased == "current location" || lowercased == "currentlocation" || lowercased == "my location" {
            return nil
        }
        return value
    }

    private static func travelMode(from raw: String?) -> SharedRouteTravelMode {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "d", "drive", "driving":
            .driving
        case "w", "walk", "walking":
            .walking
        case "r", "transit", "public_transit":
            .transit
        case "b", "bike", "bicycling", "cycling":
            .bicycling
        default:
            .unknown
        }
    }

    private static func waypointCount(from raw: String?) -> Int {
        guard let raw else { return 0 }
        return min(20, raw.split(separator: "|").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count)
    }

    private static func urls(in text: String) -> [URL] {
        guard text.count <= maximumURLLength * 2 else { return [] }
        let pattern = #"(?i)(?:https?://|comgooglemaps://)[^\s<>()]+"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard let matchedRange = Range(match.range, in: text) else { return nil }
            let candidate = String(text[matchedRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            guard candidate.count <= maximumURLLength else { return nil }
            return URL(string: candidate)
        }
    }

    private static func isSafeLength(_ url: URL) -> Bool {
        !url.absoluteString.isEmpty && url.absoluteString.count <= maximumURLLength
    }

    private static let supportedGoogleDomains: Set<String> = [
        "google.com", "google.ca", "google.co.uk", "google.com.au", "google.co.nz",
        "google.de", "google.fr", "google.es", "google.it", "google.nl", "google.be",
        "google.ch", "google.at", "google.se", "google.no", "google.dk", "google.fi",
        "google.pl", "google.pt", "google.ie", "google.co.jp", "google.co.in",
        "google.com.sg", "google.com.my", "google.com.ph", "google.co.kr", "google.com.hk",
        "google.com.tw", "google.co.th", "google.com.br", "google.com.mx", "google.com.ar",
        "google.cl", "google.co.za", "google.ae", "google.co.il", "google.com.tr"
    ]

    private static func isGoogleShortLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" &&
            url.host?.lowercased() == "maps.app.goo.gl" &&
            !url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
    }

    static func isTrustedGoogleMapsHost(_ host: String?) -> Bool {
        guard let host else { return false }
        let normalizedHost = host.lowercased()
        if supportedGoogleDomains.contains(normalizedHost) {
            return true
        }
        for prefix in ["www.", "maps."] where normalizedHost.hasPrefix(prefix) {
            return supportedGoogleDomains.contains(String(normalizedHost.dropFirst(prefix.count)))
        }
        return false
    }

    static func isTrustedGoogleRedirectURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              isSafeLength(url) else {
            return false
        }
        return url.host?.lowercased() == "maps.app.goo.gl" || isTrustedGoogleMapsHost(url.host)
    }

    private static func isGoogleMapsURL(_ url: URL) -> Bool {
        guard isTrustedGoogleMapsHost(url.host) else { return false }
        let host = url.host?.lowercased() ?? ""
        if host.hasPrefix("maps.") {
            return true
        }
        return url.path == "/maps" || url.path.hasPrefix("/maps/")
    }
}

/// Small, bounded local handoff storage shared by the app and its Share
/// extension. It uses a coordinated App Group file instead of a shared
/// UserDefaults blob so an acknowledgement in the app cannot overwrite a
/// route that the Share extension saves at the same time. Direct routes
/// persist no raw provider URL.
struct SharedRouteInbox {
    static let appGroupIdentifier = "group.com.akhilkonduru.roam"

    private static let storageFileName = "shared-route-inbox-v1.json"
    /// Holds an inbox this build could not decode, so a shared route survives
    /// a schema change instead of being erased on the first read.
    private static let quarantinedStorageFileName = "shared-route-inbox-v1-quarantined.json"
    private static let maximumEntries = 5
    private static let directRouteLifetime: TimeInterval = 60 * 60 * 24
    private static let unresolvedLinkLifetime: TimeInterval = 60 * 15

    private let storageDirectory: URL?

    init(
        storageDirectory: URL? = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        )
    ) {
        self.storageDirectory = storageDirectory
    }

    @discardableResult
    func enqueue(route: SharedRouteDraft, now: Date = Date()) -> Bool {
        mutate(now: now) { entries in
            entries.removeAll { $0.id == route.id }
            entries.append(
                StoredEntry(
                    id: route.id,
                    receivedAt: route.importedAt,
                    expiresAt: max(route.importedAt, now).addingTimeInterval(Self.directRouteLifetime),
                    route: route,
                    unresolvedGoogleURL: nil
                )
            )
            return true
        }
    }

    @discardableResult
    func enqueueGoogleShortLink(_ url: URL, id: UUID = UUID(), now: Date = Date()) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.absoluteString.count <= SharedRouteImportParser.maximumURLLength else {
            return false
        }
        return mutate(now: now) { entries in
            entries.removeAll { $0.id == id }
            entries.append(
                StoredEntry(
                    id: id,
                    receivedAt: now,
                    expiresAt: now.addingTimeInterval(Self.unresolvedLinkLifetime),
                    route: nil,
                    unresolvedGoogleURL: url.absoluteString
                )
            )
            return true
        }
    }

    func peek(now: Date = Date()) -> SharedRouteInboxItem? {
        // Persist the pruning pass before returning an item. This keeps the
        // privacy lifetime real: expired endpoints and temporary raw short
        // links are removed from the App Group file, not merely hidden.
        guard pruneExpiredEntries(now: now) else { return nil }
        return readEntries()
            .filter { $0.expiresAt > now && $0.item != nil }
            .sorted { $0.receivedAt < $1.receivedAt }
            .first?.item
    }

    /// True when something is stored that this build cannot decode. The route
    /// is kept rather than deleted, so the app can explain the gap instead of
    /// showing an empty inbox that looks like nothing was ever shared.
    var hasUnreadableEntries: Bool {
        guard let directory = preparedStorageDirectory() else { print("no directory in mutate"); return false }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var isUnreadable = false
        coordinator.coordinate(
            readingItemAt: directory,
            options: .withoutChanges,
            error: &coordinationError
        ) { coordinatedDirectory in
            if case .unreadable = readStoredEntries(in: coordinatedDirectory) {
                isUnreadable = true
            }
        }
        return coordinationError == nil && isUnreadable
    }

    func acknowledge(id: UUID, now: Date = Date()) {
        _ = mutate(now: now) { entries in
            let countBefore = entries.count
            entries.removeAll { $0.id == id }
            return entries.count != countBefore
        }
    }

    @discardableResult
    func replaceGoogleShortLink(id: UUID, with route: SharedRouteDraft, now: Date = Date()) -> Bool {
        mutate(now: now) { entries in
            guard let index = entries.firstIndex(where: { entry in
                entry.id == id && entry.unresolvedGoogleURL != nil
            }) else {
                return false
            }
            let previousEntry = entries[index]
            entries[index] = StoredEntry(
                id: id,
                receivedAt: previousEntry.receivedAt,
                expiresAt: max(route.importedAt, now).addingTimeInterval(Self.directRouteLifetime),
                route: route,
                unresolvedGoogleURL: nil
            )
            return true
        }
    }

    private func mutate(
        now: Date,
        transform: (inout [StoredEntry]) -> Bool
    ) -> Bool {
        guard let directory = preparedStorageDirectory() else { return false }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var didPersist = false
        coordinator.coordinate(
            writingItemAt: directory,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedDirectory in
            // An unreadable file must never be treated as "no shared routes".
            // Writing the resulting empty list back would delete the route the
            // driver just shared, with no card and no error — the same way an
            // unreadable drive history used to be destroyed on first read.
            let stored: [StoredEntry]
            switch readStoredEntries(in: coordinatedDirectory) {
            case let .entries(readable):
                stored = readable
            case let .unreadable(data):
                quarantine(data, in: coordinatedDirectory)
                return
            }

            var entries = stored.filter { $0.expiresAt > now && $0.item != nil }
            guard transform(&entries) else { return }

            entries.sort { $0.receivedAt < $1.receivedAt }
            didPersist = persist(
                Array(entries.suffix(Self.maximumEntries)),
                in: coordinatedDirectory
            )
        }
        if let coordinationError { print("coordination error: \(coordinationError)") }
        print("didPersist: \(didPersist)")
        return coordinationError == nil && didPersist
    }

    private func pruneExpiredEntries(now: Date) -> Bool {
        mutate(now: now) { _ in true }
    }

    private func readEntries() -> [StoredEntry] {
        guard let directory = preparedStorageDirectory() else { return [] }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var entries: [StoredEntry] = []
        coordinator.coordinate(
            readingItemAt: directory,
            options: .withoutChanges,
            error: &coordinationError
        ) { coordinatedDirectory in
            entries = decodedEntries(in: coordinatedDirectory)
        }
        return coordinationError == nil ? entries : []
    }

    private func preparedStorageDirectory() -> URL? {
        guard let storageDirectory else { return nil }
        do {
            try FileManager.default.createDirectory(
                at: storageDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            return storageDirectory
        } catch {
            print("prepare directory error: \(error)")
            return nil
        }
    }

    /// Distinguishes "nothing is stored" from "something is stored that this
    /// build cannot read". The two must never share a code path: only the
    /// first one is safe to overwrite.
    private enum StoredEntriesReadResult {
        case entries([StoredEntry])
        case unreadable(Data)
    }

    private func readStoredEntries(in directory: URL) -> StoredEntriesReadResult {
        let fileURL = directory.appendingPathComponent(Self.storageFileName, isDirectory: false)
        guard let data = try? Data(contentsOf: fileURL) else {
            return .entries([])
        }
        guard let entries = try? JSONDecoder().decode([StoredEntry].self, from: data) else {
            return .unreadable(data)
        }
        return .entries(entries)
    }

    private func decodedEntries(in directory: URL) -> [StoredEntry] {
        guard case let .entries(entries) = readStoredEntries(in: directory) else { return [] }
        return entries
    }

    /// Keeps the original bytes under a separate name so a later build can
    /// still read them, and leaves the live file untouched.
    private func quarantine(_ data: Data, in directory: URL) {
        let quarantineURL = directory.appendingPathComponent(
            Self.quarantinedStorageFileName,
            isDirectory: false
        )
        do {
            try data.write(to: quarantineURL, options: .atomic)
        } catch {
            // The live file is still intact, which is the guarantee that
            // matters. A failed copy must not escalate into a deletion.
            return
        }
    }

    private func persist(_ entries: [StoredEntry], in directory: URL) -> Bool {
        let fileURL = directory.appendingPathComponent(Self.storageFileName, isDirectory: false)
        if entries.isEmpty {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return true }
            do {
                try FileManager.default.removeItem(at: fileURL)
                return true
            } catch {
                return false
            }
        }
        guard let data = try? JSONEncoder().encode(entries) else { return false }
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private struct StoredEntry: Codable, Equatable, Identifiable {
        let id: UUID
        let receivedAt: Date
        let expiresAt: Date
        let route: SharedRouteDraft?
        let unresolvedGoogleURL: String?

        var item: SharedRouteInboxItem? {
            if let route { return .route(route) }
            guard let unresolvedGoogleURL,
                  let url = URL(string: unresolvedGoogleURL) else {
                return nil
            }
            return .unresolvedGoogleShortLink(
                SharedRouteGoogleShortLink(
                    id: id,
                    url: url,
                    receivedAt: receivedAt
                )
            )
        }
    }
}

enum SharedRouteInboxItem: Equatable, Identifiable {
    case route(SharedRouteDraft)
    case unresolvedGoogleShortLink(SharedRouteGoogleShortLink)

    var id: UUID {
        switch self {
        case let .route(route):
            route.id
        case let .unresolvedGoogleShortLink(link):
            link.id
        }
    }
}

struct SharedRouteGoogleShortLink: Equatable, Identifiable {
    let id: UUID
    let url: URL
    let receivedAt: Date
}

protocol GoogleMapsShortLinkResolving {
    func resolve(_ url: URL) async throws -> URL
}

enum GoogleMapsShortLinkResolverError: LocalizedError {
    case invalidLink
    /// The redirect chain left the trusted Google allowlist, or ran past the
    /// redirect limit. Following the same link again cannot change that.
    case unsupportedRedirect
    /// The chain stayed on Google but the page it landed on was not readable
    /// as a route — a consent interstitial, a regional variant, or a response
    /// that never arrived. The same link may well work on the next attempt.
    case unreadableRedirectTarget
    case responseTooLarge

    /// Only failures that cannot change on a retry may consume the saved
    /// share. Everything else keeps the link so the advertised retry is real.
    var isPermanent: Bool {
        switch self {
        case .invalidLink, .unsupportedRedirect, .responseTooLarge:
            true
        case .unreadableRedirectTarget:
            false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidLink:
            "That Google Maps link could not be resolved."
        case .unsupportedRedirect:
            "That Google Maps link did not lead to a supported directions route."
        case .unreadableRedirectTarget:
            "Roam could not read a route from that Google Maps link this time."
        case .responseTooLarge:
            "That Google Maps link returned more data than Roam can safely read."
        }
    }
}

struct GoogleMapsShortLinkResolver: GoogleMapsShortLinkResolving {
    func resolve(_ url: URL) async throws -> URL {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "maps.app.goo.gl",
              SharedRouteImportParser.isTrustedGoogleRedirectURL(url) else {
            throw GoogleMapsShortLinkResolverError.invalidLink
        }
        return try await GoogleMapsRedirectWalker().resolve(url)
    }
}

/// Resolves a Google Maps short link without allowing the network request to
/// become a general-purpose URL fetcher. Every redirect must remain HTTPS on a
/// small Google allowlist. The final response is accepted from its headers and
/// cancelled before its body is read.
private final class GoogleMapsRedirectWalker: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    private static let maximumRedirects = 5
    private static let maximumResponseBytes = 32 * 1_024

    private let lock = NSLock()
    private var redirectCount = 0
    private var receivedBytes = 0
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var didFinish = false

    func resolve(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 10
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.httpMaximumConnectionsPerHost = 1

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 8
            request.setValue("Roam Route Import", forHTTPHeaderField: "User-Agent")

            lock.lock()
            self.continuation = continuation
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            lock.unlock()
            let task = session.dataTask(with: request)
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let currentURL = response.url,
              let redirectURL = request.url,
              SharedRouteImportParser.isTrustedGoogleRedirectURL(currentURL),
              SharedRouteImportParser.isTrustedGoogleRedirectURL(redirectURL),
              incrementRedirectCountIfAllowed() else {
            completionHandler(nil)
            finish(.failure(GoogleMapsShortLinkResolverError.unsupportedRedirect))
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode),
              let finalURL = response.url,
              SharedRouteImportParser.isTrustedGoogleRedirectURL(finalURL) else {
            completionHandler(.cancel)
            finish(.failure(GoogleMapsShortLinkResolverError.unsupportedRedirect))
            return
        }

        // The chain ended on a trusted Google host but the page is not one
        // Roam can read as a route. That is often a consent interstitial, so
        // it is transient, not a reason to throw the share away.
        guard case .ready = SharedRouteImportParser.parse(url: finalURL, text: nil) else {
            completionHandler(.cancel)
            finish(.failure(GoogleMapsShortLinkResolverError.unreadableRedirectTarget))
            return
        }

        finish(.success(finalURL))
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        receivedBytes += data.count
        let exceededLimit = receivedBytes > Self.maximumResponseBytes
        lock.unlock()

        guard exceededLimit else { return }
        dataTask.cancel()
        finish(.failure(GoogleMapsShortLinkResolverError.responseTooLarge))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
        } else {
            // The task completed without ever producing a usable response.
            // Nothing here proves the link is bad, so it stays retriable.
            finish(.failure(GoogleMapsShortLinkResolverError.unreadableRedirectTarget))
        }
    }

    private func incrementRedirectCountIfAllowed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard redirectCount < Self.maximumRedirects else { return false }
        redirectCount += 1
        return true
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        let continuation = self.continuation
        let session = self.session
        self.continuation = nil
        self.session = nil
        lock.unlock()

        session?.invalidateAndCancel()

        switch result {
        case let .success(url):
            continuation?.resume(returning: url)
        case let .failure(error):
            continuation?.resume(throwing: error)
        }
    }
}
