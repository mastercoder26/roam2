import SwiftUI
import UIKit
import ClerkKit

struct ShowDriveTabAction {
    let perform: () -> Void

    func callAsFunction() {
        perform()
    }
}

private struct ShowDriveTabActionKey: EnvironmentKey {
    static let defaultValue = ShowDriveTabAction(perform: {})
}

extension EnvironmentValues {
    var showDriveTab: ShowDriveTabAction {
        get { self[ShowDriveTabActionKey.self] }
        set { self[ShowDriveTabActionKey.self] = newValue }
    }
}

struct RoamRootView: View {
    @ObservedObject private var theme = ThemeManager.shared
    private enum AppTab: String, CaseIterable, Identifiable {
        case routes
        case drive
        case progress
        case profile

        var id: String { rawValue }
        var title: String {
            switch self {
            case .routes: "Routes"
            case .drive: "Drive"
            case .progress: "Progress"
            case .profile: "Profile"
            }
        }

        var symbol: String {
            switch self {
            case .routes: "map.fill"
            case .drive: "steeringwheel"
            case .progress: "chart.line.uptrend.xyaxis"
            case .profile: "person.crop.circle"
            }
        }
    }

    @State private var selectedTab: AppTab = .routes
    @EnvironmentObject private var driveSession: DriveSessionManager
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var authSession: AuthSessionStore
    @Environment(Clerk.self) private var clerk
    @StateObject private var routeForm = RoutePlanningFormModel()
    @StateObject private var sharedRouteImport = SharedRouteImportCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            if !driveSession.isRecording {
                topBrandBar
            }

            // Keep the four destinations stable. The minimized iOS 26 bar can
            // retain only the selected icon while a nested NavigationStack is
            // scrolling, which obscures content and makes switching tabs much
            // harder precisely when someone is reading a detail screen.
            TabView(selection: $selectedTab) {
                Tab(AppTab.routes.title, systemImage: AppTab.routes.symbol, value: AppTab.routes) {
                    HomeView(form: routeForm)
                }
                Tab(AppTab.drive.title, systemImage: AppTab.drive.symbol, value: AppTab.drive) {
                    DriveView()
                }
                Tab(AppTab.progress.title, systemImage: AppTab.progress.symbol, value: AppTab.progress) {
                    DriverProgressView()
                }
                Tab(AppTab.profile.title, systemImage: AppTab.profile.symbol, value: AppTab.profile) {
                    ProfileView()
                }
            }
            .tabBarMinimizeBehavior(.never)
            .toolbar(driveSession.isRecording ? .hidden : .visible, for: .tabBar)
            .environment(
                \.showDriveTab,
                ShowDriveTabAction {
                    withAnimation(AppAnimation.tabSwitch) {
                        selectedTab = .drive
                    }
                }
            )
        }
        .environmentObject(driveSession)
        .environmentObject(themeManager)
        // System chrome — tab bar selection, toolbar buttons, text carets —
        // reads the tint, not AppDesign. Without this the bar kept the stock
        // blue selection on every theme.
        .tint(AppDesign.accent)
        .background(themeManager.palette.canvas.color.ignoresSafeArea())
        .preferredColorScheme(themeManager.preferredColorScheme)
        .onChange(of: driveSession.practiceRoutePresentationRequest) { _, request in
            // The manager emits this only when a Results-screen action queues a
            // route for practice. Keeping the request separate from the route
            // itself avoids coupling tab presentation to transient view state.
            guard request != nil, selectedTab != .drive else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            selectedTab = .drive
        }
        .onAppear {
            refreshSharedRouteIfSafe()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            refreshSharedRouteIfSafe()
            Task { await authSession.retryProfileSync() }
        }
        .onChange(of: driveSession.isRecording) { _, isRecording in
            guard !isRecording else { return }
            refreshSharedRouteIfSafe()
        }
        .onChange(of: sharedRouteImport.state) { _, state in
            applySharedRouteStateIfSafe(state)
        }
        .onChange(of: clerk.user?.id, initial: true) { _, _ in
            Task { await authSession.synchronizeWithClerk() }
        }
        .onOpenURL { url in
            Task { try? await Clerk.shared.handle(url) }
        }
    }

    /// A compact, ordinary layout element rather than an overlay. That makes
    /// its occupied height explicit to every tab and prevents the active
    /// screen's title from disappearing behind a safe-area inset.
    private var topBrandBar: some View {
        HStack {
            Spacer(minLength: 0)

            BrandWordmark(compact: true)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: HeaderWordmarkFrameKey.self,
                            value: proxy.frame(in: .named(LaunchIntroDockSpace.name))
                        )
                    }
                )

            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(themeManager.palette.canvas.color)
    }

    private func refreshSharedRouteIfSafe() {
        // A route import must never pull someone out of a manually started
        // drive. The inbox remains local and will be read after the drive ends.
        guard !driveSession.isRecording else { return }
        Task {
            await sharedRouteImport.refresh()
        }
    }

    private func applySharedRouteStateIfSafe(_ state: SharedRouteImportCoordinator.State) {
        guard !driveSession.isRecording else { return }

        switch state {
        case let .ready(route):
            routeForm.apply(route)
            sharedRouteImport.acknowledgeReadyRoute(id: route.id)
            selectedTab = .routes

        case let .failed(message):
            routeForm.presentImportError(message)
            sharedRouteImport.dismissFailure()
            selectedTab = .routes

        case .idle, .resolvingGoogleMapsLink:
            break
        }
    }
}

#Preview {
    RoamRootView()
        .environmentObject(ThemeManager.shared)
        .environmentObject(DriveSessionManager.shared)
        .environmentObject(AuthSessionStore.shared)
}
