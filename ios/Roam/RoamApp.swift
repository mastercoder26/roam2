import SwiftUI
import ClerkKit

@main
struct RoamApp: App {
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var driveSession = DriveSessionManager.shared
    @StateObject private var authSession = AuthSessionStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isIntroPlaying = true
    @State private var leftForegroundAt: Date?
    /// The header wordmark's live frame, read from `RoamRootView` (which sits
    /// behind the intro, just invisible, for its entire run) so the intro's
    /// docked wordmark lands exactly where the real header's does.
    @State private var headerWordmarkFrame: CGRect = .zero

    init() {
        Clerk.configure(publishableKey: "pk_test_Y2FwYWJsZS1zd2FuLTM1LmNsZXJrLmFjY291bnRzLmRldiQ")
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RoamRootView()
                    .environmentObject(themeManager)
                    .environmentObject(driveSession)
                    .environmentObject(authSession)
                    .environment(Clerk.shared)
                    // The app sits very slightly forward behind the intro, so
                    // the handoff settles into place instead of cutting.
                    .scaleEffect(isIntroPlaying && !reduceMotion ? 1.03 : 1)
                    .opacity(isIntroPlaying ? 0 : 1)
                    .allowsHitTesting(!isIntroPlaying)

                if isIntroPlaying {
                    LaunchIntroView(onFinish: finishIntro, dockTargetFrame: headerWordmarkFrame)
                        .environmentObject(themeManager)
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .coordinateSpace(name: LaunchIntroDockSpace.name)
            .onPreferenceChange(HeaderWordmarkFrameKey.self) { headerWordmarkFrame = $0 }
            .preferredColorScheme(themeManager.preferredColorScheme)
            .task {
                authSession.configureDriveHistorySync {
                    let driveSession = DriveSessionManager.shared
                    DriveHistorySyncService.shared.sync(
                        localDrives: driveSession.recordedDrives,
                        applyLocalDrives: { drives in
                            driveSession.applySyncedRecordedDrives(drives)
                        }
                    )
                }
                await authSession.restoreIfNeeded()
            }
            .onChange(of: scenePhase) { _, phase in
                handleScenePhase(phase)
            }
        }
    }

    private func finishIntro() {
        withAnimation(.easeOut(duration: LaunchIntroChoreography.exitDuration)) {
            isIntroPlaying = false
        }
    }

    /// iOS rarely terminates an app, so "every time it is opened" has to mean
    /// returning after a real absence rather than every task-switcher glance —
    /// and never in the middle of a recorded drive.
    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background, .inactive:
            guard !isIntroPlaying, leftForegroundAt == nil else { return }
            leftForegroundAt = Date()

        case .active:
            authSession.requestDriveHistorySync()
            authSession.requestProfileSync()
            driveSession.resumeRouteAnalysesIfNeeded()
            guard let leftAt = leftForegroundAt else { return }
            leftForegroundAt = nil
            guard LaunchIntroChoreography.shouldReplay(
                awayFor: Date().timeIntervalSince(leftAt),
                isRecording: driveSession.isRecording
            ) else { return }
            isIntroPlaying = true

        @unknown default:
            break
        }
    }
}
