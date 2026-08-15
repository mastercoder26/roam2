import Combine
import Foundation

#if canImport(ClerkKit)
import ClerkKit
#endif

enum ProfileSyncAction: Equatable {
    case pullRemote
    case pushLocal
    case none
}

enum ProfileSyncConflictResolver {
    static func resolve(
        local: DriverProfile,
        localUpdatedAt: Date,
        remote: RemoteProfile?
    ) -> ProfileSyncAction {
        let localIsEmpty = local.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && local.stage == .permit

        guard let remote else { return localIsEmpty ? .none : .pushLocal }

        let remoteIsEmpty = remote.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && remote.stage == .permit
            && remote.payload.isEmpty
        if remoteIsEmpty { return localIsEmpty ? .none : .pushLocal }
        if localIsEmpty { return .pullRemote }
        return remote.updatedAt >= localUpdatedAt ? .pullRemote : .pushLocal
    }
}

@MainActor
final class AuthSessionStore: ObservableObject {
    enum State: Equatable {
        case restoring
        case signedOut
        case authenticating
        case signedIn(AuthUser)
        case signedInOffline(AuthUser)
    }

    enum SyncStatus: Equatable {
        case synced
        case syncing
        case workingOffline
        case failed(String)
    }

    static let shared = AuthSessionStore()

    @Published private(set) var state: State = .restoring
    @Published private(set) var syncStatus: SyncStatus = .synced

    private let client: ClerkBackendClient
    private var testAccessToken: String?
    private var hasStartedRestore = false
    private var isProfileSyncInFlight = false
    private var driveHistorySyncRequest: (() -> Void)?

    init(
        client: ClerkBackendClient = ClerkBackendClient(),
        automaticallyRestore: Bool = true
    ) {
        self.client = client
        guard automaticallyRestore else { return }
        Task { @MainActor [weak self] in
            await self?.restoreIfNeeded()
        }
    }

    var currentUser: AuthUser? {
        switch state {
        case let .signedIn(user), let .signedInOffline(user): user
        case .restoring, .signedOut, .authenticating: nil
        }
    }

    var isSignedIn: Bool {
        switch state {
        case .signedIn, .signedInOffline: true
        case .restoring, .signedOut, .authenticating: false
        }
    }

    /// Synchronizes the app-facing state with Clerk's observable user. This is
    /// called on launch and whenever the prebuilt views activate or end a
    /// Clerk session.
    func synchronizeWithClerk() async {
        #if canImport(ClerkKit)
        guard let clerkUser = Clerk.shared.user else {
            markSignedOut()
            return
        }

        let clerkIdentity = AuthUser(
            id: clerkUser.id,
            email: clerkUser.primaryEmailAddress?.emailAddress ?? "",
            displayName: [clerkUser.firstName, clerkUser.lastName]
                .compactMap { $0 }
                .joined(separator: " ")
                .nilIfEmpty
        )
        state = .signedIn(clerkIdentity)

        do {
            let backendUser = try await performAuthenticated { token in
                try await self.client.currentUser(accessToken: token)
            }
            state = .signedIn(backendUser)
            await syncProfile()
            requestDriveHistorySync()
        } catch {
            state = .signedInOffline(clerkIdentity)
            syncStatus = .workingOffline
            requestDriveHistorySync()
        }
        #else
        if !isSignedIn { state = .signedOut }
        #endif
    }

    func restoreIfNeeded() async {
        guard !hasStartedRestore else { return }
        hasStartedRestore = true
        state = .restoring
        await synchronizeWithClerk()
    }

    /// Clerk owns sign-in and sign-up through AuthView. These methods are
    /// intentionally absent: the app must never call the removed custom
    /// /api/auth/signup or /api/auth/login endpoints.

    func signOut() async throws {
        #if canImport(ClerkKit)
        try await Clerk.shared.auth.signOut()
        #endif
        markSignedOut()
    }

    func deleteAccount() async throws {
        try await performAuthenticated { token in
            try await self.client.deleteAccount(accessToken: token)
        }
        DriverProfileStore.shared.reset()
        #if canImport(ClerkKit)
        try await Clerk.shared.auth.signOut()
        #endif
        markSignedOut()
    }

    func retryProfileSync() async {
        await synchronizeWithClerk()
    }

    func requestDriveHistorySync() {
        guard isSignedIn else { return }
        driveHistorySyncRequest?()
    }

    /// Re-runs profile reconciliation outside the cold-launch path.
    ///
    /// `restoreIfNeeded()` runs once per process, so without this a profile
    /// edit made in one session — advancing a learner stage, changing a display
    /// name — stayed local until the app was fully killed and relaunched.
    /// `syncProfile()` resolves conflicts in both directions, so repeating it
    /// on foreground is safe and simply converges.
    func requestProfileSync() {
        guard isSignedIn, !isProfileSyncInFlight else { return }
        isProfileSyncInFlight = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isProfileSyncInFlight = false }
            await self.syncProfile()
        }
    }

    func configureDriveHistorySync(_ request: @escaping () -> Void) {
        driveHistorySyncRequest = request
        if isSignedIn { request() }
    }

    /// Stable contract used by DriveHistorySyncService. Clerk returns a
    /// short-lived session token and refreshes it internally; this method only
    /// hands that current token to the authenticated operation.
    func performAuthenticated<Response>(
        _ operation: @escaping (String) async throws -> Response
    ) async throws -> Response {
        #if canImport(ClerkKit)
        guard Clerk.shared.user != nil else {
            throw AuthError.unauthorized(message: "Sign in to continue.")
        }
        guard let token = try await Clerk.shared.auth.getToken() else {
            throw AuthError.unauthorized(message: "Your Clerk session is not available. Sign in again.")
        }
        return try await operation(token)
        #else
        guard let token = testAccessToken else {
            throw AuthError.unauthorized(message: "Sign in to continue.")
        }
        return try await operation(token)
        #endif
    }

    /// Test-only state injection for the standalone drive-sync checks. It does
    /// not persist credentials or participate in production Clerk state.
    func setSignedInForTesting(user: AuthUser, accessToken: String) {
        testAccessToken = accessToken
        state = .signedIn(user)
    }

    private func syncProfile() async {
        guard let user = currentUser else { return }
        syncStatus = .syncing

        do {
            let remote = try await performAuthenticated { token in
                try await self.client.profile(accessToken: token)
            }
            let localStore = DriverProfileStore.shared
            switch ProfileSyncConflictResolver.resolve(
                local: localStore.snapshot,
                localUpdatedAt: localStore.lastUpdatedAt,
                remote: remote
            ) {
            case .pullRemote:
                localStore.applyRemoteProfile(
                    displayName: remote.displayName,
                    stage: remote.stage,
                    updatedAt: remote.updatedAt
                )
            case .pushLocal:
                let local = localStore.snapshot
                let updated = try await performAuthenticated { token in
                    try await self.client.updateProfile(
                        accessToken: token,
                        displayName: local.displayName,
                        stage: local.stage,
                        payload: nil
                    )
                }
                localStore.applyRemoteProfile(
                    displayName: updated.displayName,
                    stage: updated.stage,
                    updatedAt: updated.updatedAt
                )
            case .none:
                break
            }
            state = .signedIn(user)
            syncStatus = .synced
        } catch let error as AuthError {
            if error.isTransient {
                state = .signedInOffline(user)
                syncStatus = .workingOffline
            } else {
                syncStatus = .failed(error.localizedDescription)
            }
        } catch {
            syncStatus = .failed("Profile sync failed. Try again.")
        }
    }

    private func markSignedOut() {
        testAccessToken = nil
        state = .signedOut
        syncStatus = .synced
        DriveHistorySyncService.shared.didSignOut()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

typealias AuthSessionState = AuthSessionStore.State
