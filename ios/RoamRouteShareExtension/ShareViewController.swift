import OSLog
import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let model = ShareRouteImportViewModel()

    override func viewDidLoad() {
        super.viewDidLoad()

        let controller = UIHostingController(
            rootView: RouteShareImportView(
                model: model,
                finish: { [weak self] in
                    self?.extensionContext?.completeRequest(returningItems: nil)
                }
            )
        )
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        controller.didMove(toParent: self)

        let attachments = (extensionContext?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []
        Task { [model] in
            let outcome = await SharedRouteShareItemReader.read(from: attachments)
            model.importRoute(from: outcome)
        }
    }
}

@MainActor
private final class ShareRouteImportViewModel: ObservableObject {
    enum State {
        case loading
        case saved(SharedRouteDraft?)
        case savedGoogleShortLink
        case unsupported(String)
    }

    @Published private(set) var state: State = .loading
    private let inbox = SharedRouteInbox()

    func importRoute(from outcome: SharedRouteShareItemReader.Outcome) {
        let sharedItem: SharedRouteShareItem
        switch outcome {
        case let .item(item):
            sharedItem = item
        case .attachmentFailedToLoad:
            // Distinct from an unsupported link: the attachment was the right
            // kind, the system just could not hand it over. Retrying the same
            // share can work, so say so instead of blaming the link.
            state = .unsupported("Roam could not read the shared item. Try sharing the route again.")
            return
        case .noSupportedAttachment:
            state = .unsupported("Share a route link from Apple Maps or Google Maps to add it to Roam.")
            return
        }

        switch SharedRouteImportParser.parse(url: sharedItem.url, text: sharedItem.text) {
        case let .ready(candidate):
            let route = SharedRouteDraft(
                id: UUID(),
                provider: candidate.provider,
                origin: candidate.origin,
                destination: candidate.destination,
                importedAt: Date(),
                waypointCount: candidate.waypointCount
            )
            guard inbox.enqueue(route: route) else {
                state = .unsupported("Roam could not save this route. Make sure the app's shared storage capability is enabled.")
                return
            }
            state = .saved(route)

        case let .needsGoogleShortLinkResolution(url):
            guard inbox.enqueueGoogleShortLink(url) else {
                state = .unsupported("Roam could not save this Google Maps link.")
                return
            }
            state = .savedGoogleShortLink

        case let .unsupportedTravelMode(mode):
            state = .unsupported("This link is for \(mode.displayName). Roam can only analyze driving routes.")

        case let .unsupported(message):
            state = .unsupported(message)
        }
    }
}

private struct RouteShareImportView: View {
    @ObservedObject var model: ShareRouteImportViewModel
    let finish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .loading:
                    loadingContent
                case let .saved(route):
                    savedContent(route: route)
                case .savedGoogleShortLink:
                    savedGoogleShortLinkContent
                case let .unsupported(message):
                    unsupportedContent(message: message)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Add route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: finish)
                }
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.35, dampingFraction: 1), value: stateIdentity)
    }

    private var stateIdentity: String {
        switch model.state {
        case .loading: "loading"
        case .saved: "saved"
        case .savedGoogleShortLink: "short-link"
        case .unsupported: "unsupported"
        }
    }

    private var loadingContent: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(.accentColor)
            Text("Reading your map route")
                .font(.headline)
            Text("Roam is preparing the route for you to review.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 240, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reading your map route")
    }

    private func savedContent(route: SharedRouteDraft?) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            statusHeader(
                title: "Route saved for Roam",
                detail: "Open Roam to review the route, choose a departure time, and analyze it.",
                symbol: "checkmark.circle.fill",
                color: .green
            )

            if let route {
                VStack(alignment: .leading, spacing: 12) {
                    routeRow(title: "From", value: route.origin ?? "Current location")
                    Divider()
                    routeRow(title: "To", value: route.destination)
                    if route.waypointCount > 0 {
                        Divider()
                        Text("Roam will ask you to review the start and final destination. This route has \(route.waypointCount) additional stop\(route.waypointCount == 1 ? "" : "s").")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            Button(action: finish) {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Closes this share sheet. Open Roam to review the imported route.")
        }
    }

    private var savedGoogleShortLinkContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            statusHeader(
                title: "Google Maps link saved",
                detail: "Open Roam to finish preparing the route, then review and analyze it.",
                symbol: "link.circle.fill",
                color: .accentColor
            )

            Text("Roam only follows the shared Google Maps link after you return to the app. It will not start a route analysis by itself.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            Button(action: finish) {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func unsupportedContent(message: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            statusHeader(
                title: "Route not added",
                detail: message,
                symbol: "exclamationmark.triangle.fill",
                color: .orange
            )

            Text("Share a driving route from Apple Maps or Google Maps. Roam will fill in the route for you to review before analysis.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            Button(action: finish) {
                Text("Close")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.bordered)
        }
    }

    private func statusHeader(
        title: String,
        detail: String,
        symbol: String,
        color: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 46, height: 46)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func routeRow(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
            Text(value)
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SharedRouteShareItem {
    let url: URL?
    let text: String?
}

private enum SharedRouteShareItemReader {
    /// Separates "nothing here Roam can use" from "the attachment was the
    /// right kind but the system failed to hand it over". Collapsing the two
    /// makes a transient load failure read as an unsupported link, so the user
    /// retries the same share expecting a different outcome.
    enum Outcome {
        case item(SharedRouteShareItem)
        case attachmentFailedToLoad
        case noSupportedAttachment
    }

    /// The result of asking one provider for one type.
    private enum Load<Value> {
        /// The provider does not offer this type at all.
        case notOffered
        case loaded(Value)
        /// The provider offered this type and failed to produce it.
        case failed(Error?)
    }

    static func read(from attachments: [NSItemProvider]) async -> Outcome {
        var sawLoadFailure = false

        for provider in attachments {
            switch await loadURL(from: provider) {
            case let .loaded(url):
                return .item(SharedRouteShareItem(url: url, text: nil))
            case let .failed(error):
                log(error, forType: "URL")
                sawLoadFailure = true
            case .notOffered:
                continue
            }
        }

        for provider in attachments {
            switch await loadText(from: provider) {
            case let .loaded(text):
                return .item(SharedRouteShareItem(url: nil, text: text))
            case let .failed(error):
                log(error, forType: "plain text")
                sawLoadFailure = true
            case .notOffered:
                continue
            }
        }

        return sawLoadFailure ? .attachmentFailedToLoad : .noSupportedAttachment
    }

    private static func log(_ error: Error?, forType type: String) {
        // The underlying error is diagnostic detail, not user-facing copy.
        logger.error("Share attachment (\(type, privacy: .public)) failed to load: \(error?.localizedDescription ?? "no error reported", privacy: .public)")
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.roam.share",
        category: "SharedRouteShareItemReader"
    )

    private static func loadURL(from provider: NSItemProvider) async -> Load<URL> {
        guard provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) else { return .notOffered }
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, error in
                if let url = item as? URL {
                    continuation.resume(returning: .loaded(url))
                } else if let url = item as? NSURL {
                    continuation.resume(returning: .loaded(url as URL))
                } else if let string = item as? String, let url = URL(string: string) {
                    continuation.resume(returning: .loaded(url))
                } else {
                    continuation.resume(returning: .failed(error))
                }
            }
        }
    }

    private static func loadText(from provider: NSItemProvider) async -> Load<String> {
        guard provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) else { return .notOffered }
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, error in
                if let string = item as? String {
                    continuation.resume(returning: .loaded(string))
                } else if let string = item as? NSString {
                    continuation.resume(returning: .loaded(string as String))
                } else {
                    continuation.resume(returning: .failed(error))
                }
            }
        }
    }
}

private extension SharedRouteTravelMode {
    var displayName: String {
        switch self {
        case .driving:
            "driving"
        case .walking:
            "walking"
        case .transit:
            "transit"
        case .bicycling:
            "bicycling"
        case .unknown:
            "an unsupported mode"
        }
    }
}
