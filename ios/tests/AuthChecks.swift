import Foundation

@main
struct AuthChecks {
    @MainActor
    static func main() async {
        await authenticatedOperationUsesClerkSessionTokenContract()
        await signedOutOperationsAreRejected()
        await signingOutEndsTheSessionWithoutDeletingTheAccount()
        errorResponsesRemainSafeAndBranchable()
        remoteProfileDecoderTreatsNullStageAsPermit()
        profileConflictRulePrefersTheNewerSource()

        print("Auth checks passed")
    }

    @MainActor
    private static func authenticatedOperationUsesClerkSessionTokenContract() async {
        let user = AuthUser(id: "clerk-user", email: "driver@example.com", displayName: "Driver")
        let session = AuthSessionStore(automaticallyRestore: false)
        session.setSignedInForTesting(user: user, accessToken: "clerk-session-token")

        do {
            let returned = try await session.performAuthenticated { token in
                expect(token == "clerk-session-token", "authenticated work must receive the current Clerk session token")
                return token
            }
            expect(returned == "clerk-session-token", "authenticated work should return its result")
        } catch {
            fail("Clerk session token contract failed: \(error)")
        }
    }

    @MainActor
    private static func signedOutOperationsAreRejected() async {
        let session = AuthSessionStore(automaticallyRestore: false)
        do {
            _ = try await session.performAuthenticated { _ in "unexpected" }
            fail("signed-out authenticated work must not run")
        } catch let error as AuthError {
            expect(error.code == .unauthorized, "signed-out authenticated work should report unauthorized")
        } catch {
            fail("signed-out authenticated work returned the wrong error: \(error)")
        }
    }

    @MainActor
    private static func signingOutEndsTheSessionWithoutDeletingTheAccount() async {
        let user = AuthUser(id: "clerk-user", email: "driver@example.com", displayName: "Driver")
        let session = AuthSessionStore(automaticallyRestore: false)
        session.setSignedInForTesting(user: user, accessToken: "clerk-session-token")

        do {
            try await session.signOut()
        } catch {
            fail("sign out should end the local session without failing: \(error)")
        }

        expect(session.state == .signedOut, "sign out should clear the signed-in state")
        expect(session.currentUser == nil, "sign out should clear the current user")

        do {
            _ = try await session.performAuthenticated { _ in "unexpected" }
            fail("authenticated work must not run after sign out")
        } catch let error as AuthError {
            expect(error.code == .unauthorized, "authenticated work after sign out should be unauthorized")
        } catch {
            fail("sign out returned the wrong follow-up error: \(error)")
        }
    }

    private static func errorResponsesRemainSafeAndBranchable() {
        let body = Data(#"{"error":"Your Clerk session is not authorized for Roam.","code":"UNAUTHORIZED","requestId":"req-1"}"#.utf8)
        let error = AuthError.from(statusCode: 401, data: body)
        expect(error.code == .unauthorized, "UNAUTHORIZED should remain branchable")
        expect(error.localizedDescription == "Your Clerk session is not authorized for Roam.", "backend messages should remain user-facing")

        let malformed = AuthError.from(statusCode: 502, data: Data("<html>bad gateway</html>".utf8))
        expect(malformed.localizedDescription.count < 200, "untrusted error bodies must not become an oversized UI message")
    }

    private static func remoteProfileDecoderTreatsNullStageAsPermit() {
        let response = Data(#"{"displayName":null,"stage":null,"payload":{},"updatedAt":"2026-08-06T18:00:00.000Z"}"#.utf8)
        let profile = try? APIClient.makeDateDecoder().decode(RemoteProfile.self, from: response)

        expect(profile?.stage == .permit, "a newly-created server profile with a null stage should use the local permit default")

        let licensedResponse = Data(#"{"displayName":"Driver","stage":"licensed","payload":{},"updatedAt":"2026-08-06T18:00:00.000Z"}"#.utf8)
        let licensedProfile = try? APIClient.makeDateDecoder().decode(RemoteProfile.self, from: licensedResponse)

        expect(licensedProfile?.stage == .licensed, "a non-null server stage should remain unchanged")
    }

    private static func profileConflictRulePrefersTheNewerSource() {
        let local = DriverProfile(displayName: "Local", stage: .permit)
        let remote = RemoteProfile(displayName: "Remote", stage: .licensed, payload: [:], updatedAt: Date(timeIntervalSince1970: 200))

        expect(
            ProfileSyncConflictResolver.resolve(local: local, localUpdatedAt: Date(timeIntervalSince1970: 100), remote: remote) == .pullRemote,
            "a newer remote profile should replace the local profile"
        )
        expect(
            ProfileSyncConflictResolver.resolve(local: local, localUpdatedAt: Date(timeIntervalSince1970: 300), remote: remote) == .pushLocal,
            "a newer local profile should be pushed to the server"
        )
        expect(
            ProfileSyncConflictResolver.resolve(
                local: local,
                localUpdatedAt: Date(timeIntervalSince1970: 300),
                remote: RemoteProfile(displayName: "", stage: .permit, payload: [:], updatedAt: Date(timeIntervalSince1970: 400))
            ) == .pushLocal,
            "a non-empty local profile should be pushed when the remote profile is empty"
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        fatalError("Auth check failed: \(message)")
    }
}
